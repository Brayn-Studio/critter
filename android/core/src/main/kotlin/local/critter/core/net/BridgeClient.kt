package local.critter.core.net

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import local.critter.core.protocol.ClientMessage
import local.critter.core.protocol.DenyReason
import local.critter.core.protocol.PairingUri
import local.critter.core.protocol.ResultReason
import local.critter.core.protocol.ServerMessage
import local.critter.core.protocol.decodeServer
import local.critter.core.protocol.encode
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

data class Credentials(val deviceId: String, val token: String)

sealed interface ConnState {
    data object Idle : ConnState
    data object Connecting : ConnState

    /** Pairing: the request is with the Mac, waiting for the user to approve it there. */
    data object AwaitingApproval : ConnState
    data class Connected(val macName: String) : ConnState

    /** Disconnected; the next attempt is in [retryInMs]. [since] is when the connection was lost. */
    data class Offline(val retryInMs: Long, val since: Long) : ConnState

    /** Retrying cannot help: wrong pin, rejected token, or the Mac refused us. Pair again. */
    data class NeedsRepair(val reason: String) : ConnState
}

/** Where the Mac currently is. The app resolves this via the last good address, then NSD. */
interface Endpoint {
    suspend fun resolve(): Pair<String, Int>?
}

/**
 * One long-lived, certificate-pinned WebSocket to the Mac, with reconnect and request/result matching.
 * Not for use before [start] is called; [stop] disconnects and ends the retry loop; [close] also lets go of the
 * HTTP client for good.
 */
class BridgeClient(
    private val scope: CoroutineScope,
    private val endpoint: Endpoint,
    private val fingerprint: String,
    private val credentials: () -> Credentials?,
    private val clock: () -> Long = System::currentTimeMillis,
    private val requestTimeoutMs: Long = 10_000,
    private val pairTimeoutMs: Long = 120_000,
    private val backoff: ReconnectBackoff = ReconnectBackoff(),
    private val appName: String = "critter-android/1.0",
) {
    private val _state = MutableStateFlow<ConnState>(ConnState.Idle)
    val state: StateFlow<ConnState> = _state

    private val _snapshot = MutableStateFlow<ServerMessage.Snapshot?>(null)
    val snapshot: StateFlow<ServerMessage.Snapshot?> = _snapshot

    private val _pairing = MutableSharedFlow<ServerMessage.Paired>(extraBufferCapacity = 1)
    val pairing: SharedFlow<ServerMessage.Paired> = _pairing

    /**
     * Guards the connection loop's shared state ([run], the state while running, [socket], [offlineSince],
     * [backoff], the ping interval) against [start], [stop], [reconnectNow] and a stopped run that has not noticed yet.
     */
    private val lock = Any()

    /**
     * Which [start] the loop belongs to; [stop] moves it on. A run that is no longer current (cancelled, but still
     * finishing a step that does not suspend, or its socket's last callbacks) changes nothing.
     */
    private var run = 0
    private var closed = false

    @Volatile private var pingIntervalMs = 30_000L
    @Volatile private var http = buildHttp(fingerprint)
    @Volatile private var job: Job? = null
    @Volatile private var socket: WebSocket? = null
    private var offlineSince: Long? = null

    /** Ends the backoff wait at once. Only sent when the very next wait is the one meant ([reconnectNow]). */
    private val wake = Channel<Unit>(Channel.CONFLATED)

    /** A request waiting for its reply, and the connection it went out on: only that connection's end fails it. */
    private class Waiting<T>(val ws: WebSocket) {
        val reply = CompletableDeferred<T>()
    }

    private val inFlight = ConcurrentHashMap<String, Waiting<ServerMessage.Result>>()
    private val skinsInFlight = ConcurrentHashMap<String, Waiting<ServerMessage.Skin?>>()
    private val nextId = AtomicLong()

    private fun buildHttp(pin: String): OkHttpClient = PinnedTls.client(
        pin,
        OkHttpClient.Builder().pingInterval(pingIntervalMs, TimeUnit.MILLISECONDS).build(),
    )

    fun start() {
        synchronized(lock) {
            if (closed || job?.isActive == true) return
            val mine = ++run
            job = scope.launch { runLoop(mine) }
        }
    }

    /** Disconnects and ends the retry loop. A [start] after it begins afresh: the first wait is the shortest again. */
    fun stop() {
        val ws = synchronized(lock) {
            run++
            job?.cancel()
            job = null
            offlineSince = null
            backoff.reset()
            _state.value = ConnState.Idle
            socket.also { socket = null }
        }
        ws?.cancel()
    }

    /**
     * [stop], then shuts the HTTP client's threads and pooled connections down (shared by every client this one
     * built). For a client that is being thrown away: it does not start again.
     */
    fun close() {
        synchronized(lock) { closed = true }
        stop()
        http.dispatcher.executorService.shutdown()
        http.connectionPool.evictAll()
    }

    /**
     * Connects again without waiting: while [ConnState.Offline] it skips the rest of the backoff; while
     * [ConnState.Connected] it drops the connection (the network changed under it, say) and makes a new one at once.
     * While connecting, waiting for approval, idle or in need of re-pairing it does nothing, and leaves nothing
     * behind for later.
     */
    fun reconnectNow() {
        val drop = synchronized(lock) {
            when (_state.value) {
                is ConnState.Offline -> {
                    wake.trySend(Unit)
                    null
                }
                is ConnState.Connected -> {
                    // The loop has not left this connection yet: its very next wait is the one this ends.
                    wake.trySend(Unit)
                    socket
                }
                else -> null
            }
        }
        drop?.cancel()
    }

    /**
     * 30 s while the board is open, 3 min otherwise (spec §8.3). OkHttp fixes a WebSocket's ping interval when it
     * opens. A longer interval waits for the next connection; a shorter one renews the live connection once the
     * requests on it have their replies (at most [requestTimeoutMs]), so the board's heartbeat applies now. The
     * rebuilt client shares the old one's connection pool and dispatcher.
     */
    fun setPingInterval(ms: Long) {
        val shorter = synchronized(lock) {
            if (ms == pingIntervalMs) return
            val shorter = ms < pingIntervalMs
            pingIntervalMs = ms
            http = http.newBuilder().pingInterval(ms, TimeUnit.MILLISECONDS).build()
            shorter
        }
        if (shorter && _state.value is ConnState.Connected) socket?.let(::renewWhenSettled)
    }

    /** The ping interval the next connection will use. */
    val nextPingIntervalMs: Long get() = http.pingIntervalMillis.toLong()

    /** Drops [ws] for a new connection, at once, when nothing sent on it is still waiting for a reply. */
    private fun renewWhenSettled(ws: WebSocket) {
        scope.launch {
            withTimeoutOrNull(requestTimeoutMs) {
                while (true) {
                    val pending = inFlight.values.filter { it.ws === ws && !it.reply.isCompleted }.map { it.reply } +
                        skinsInFlight.values.filter { it.ws === ws && !it.reply.isCompleted }.map { it.reply }
                    if (pending.isEmpty()) break
                    pending.forEach { it.join() }
                }
            }
            val current = synchronized(lock) {
                (socket === ws && _state.value is ConnState.Connected).also { if (it) wake.trySend(Unit) }
            }
            if (current) ws.cancel()
        }
    }

    /**
     * Sends [msg] with a fresh correlation id and waits for the Mac's `result`. The Mac answers within milliseconds,
     * so none within [requestTimeoutMs] means the connection is broken: it is dropped (and made again) rather than
     * left looking connected.
     */
    suspend fun request(msg: ClientMessage.Command): ServerMessage.Result {
        val id = "a${nextId.incrementAndGet()}"
        val ws = socket ?: return failure(id, "未连接")
        val waiting = Waiting<ServerMessage.Result>(ws)
        inFlight[id] = waiting
        try {
            if (!ws.send(encode(msg.withId(id)))) return failure(id, "未连接")
            return withTimeoutOrNull(requestTimeoutMs) { waiting.reply.await() }
                ?: failure(id, "超时").also { ws.cancel() }
        } finally {
            inFlight.remove(id)
        }
    }

    /**
     * Asks the Mac for a skin's manifest. Null if the Mac has no such skin, the connection is down or it does not
     * answer in time (which drops the connection, as in [request]).
     */
    suspend fun requestSkin(name: String): ServerMessage.Skin? {
        val id = "a${nextId.incrementAndGet()}"
        val ws = socket ?: return null
        val waiting = Waiting<ServerMessage.Skin?>(ws)
        skinsInFlight[id] = waiting
        try {
            if (!ws.send(encode(ClientMessage.SkinRequest(id, name)))) return null
            val reply = withTimeoutOrNull(requestTimeoutMs) { waiting.reply.await() }
            if (reply == null && !waiting.reply.isCompleted) ws.cancel()
            return reply?.takeIf { it.manifest != null }
        } finally {
            skinsInFlight.remove(id)
        }
    }

    /**
     * First-time pairing over a connection pinned to the fingerprint in [uri]. Returns [PairResult.Paired] once
     * the user has approved on the Mac (up to [pairTimeoutMs]), otherwise why not ([pairFailureOf]).
     * The caller stores the returned credentials and [uri]'s fingerprint, then connects normally.
     */
    suspend fun pair(uri: PairingUri, deviceName: String): PairResult {
        _state.value = ConnState.Connecting
        val paired = CompletableDeferred<ServerMessage.Paired>()
        val link = open(
            client = PinnedTls.client(uri.fingerprint, http),
            host = uri.host,
            port = uri.port,
            first = ClientMessage.Pair(uri.code, deviceName),
            onOpen = { _state.value = ConnState.AwaitingApproval },
        ) { _, msg -> if (msg is ServerMessage.Paired) paired.complete(msg) }
        try {
            // Whichever comes first: the approval, or the connection ending (denied, refused, closed).
            val settled = withTimeoutOrNull(pairTimeoutMs) {
                val gate = CompletableDeferred<Unit>()
                link.ended.invokeOnCompletion { gate.complete(Unit) }
                paired.invokeOnCompletion { gate.complete(Unit) }
                gate.await()
            }
            if (paired.isCompleted) {
                val approved = paired.await()
                _pairing.tryEmit(approved)
                return PairResult.Paired(approved)
            }
            val why = when (val end = if (settled != null) link.ended.await() else null) {
                null -> pairFailureOf(null, null, timedOut = true, closedCleanly = false)
                is End.Denied -> pairFailureOf(end.reason, null, timedOut = false, closedCleanly = false)
                is End.Dropped -> pairFailureOf(null, end.cause, timedOut = false, closedCleanly = end.cause == null)
            }
            return PairResult.Failed(why)
        } finally {
            link.ws.cancel()
            _state.value = if (job?.isActive == true) _state.value else ConnState.Idle
        }
    }

    // --- connection loop -------------------------------------------------------------------

    /** Sets the state if [mine] is still the current run. */
    private fun setState(mine: Int, value: ConnState) {
        synchronized(lock) { if (run == mine) _state.value = value }
    }

    private suspend fun runLoop(mine: Int) {
        while (currentCoroutineContext().isActive) {
            val creds = credentials()
            if (creds == null) {
                setState(mine, ConnState.NeedsRepair("尚未配对"))
                return
            }
            synchronized(lock) {
                if (run != mine) return
                _state.value = ConnState.Connecting
                wake.tryReceive() // not meant for the wait after this attempt
            }

            val end = connectOnce(creds, mine)
            when {
                end is End.Denied -> {
                    setState(mine, ConnState.NeedsRepair(deniedText(end.reason)))
                    return
                }
                end is End.Dropped && end.cause.hasPinMismatch() -> {
                    setState(mine, ConnState.NeedsRepair("证书指纹与配对时不一致，请重新配对"))
                    return
                }
            }
            val delayMs = synchronized(lock) {
                if (run != mine) return
                val since = offlineSince ?: clock().also { offlineSince = it }
                backoff.nextDelayMs().also { _state.value = ConnState.Offline(it, since) }
            }
            withTimeoutOrNull(delayMs) { wake.receive() }
        }
    }

    private suspend fun connectOnce(creds: Credentials, mine: Int): End {
        val address = endpoint.resolve() ?: return End.Dropped(null)
        // Finding the Mac may not notice a stop (a blocking probe): a stopped run goes no further.
        currentCoroutineContext().ensureActive()
        val client = http
        val pingMs = client.pingIntervalMillis.toLong()
        val link = open(
            client = client,
            host = address.first,
            port = address.second,
            first = ClientMessage.Hello(appName, creds.deviceId, creds.token),
        ) { ws, msg ->
            when (msg) {
                is ServerMessage.Welcome -> {
                    val renew = synchronized(lock) {
                        if (run != mine) return@open
                        socket = ws // already, unless the welcome beat open()'s return
                        backoff.reset()
                        offlineSince = null
                        _state.value = ConnState.Connected(msg.macName)
                        // The board shortened the heartbeat while this connection was being made.
                        pingMs > pingIntervalMs
                    }
                    if (renew) renewWhenSettled(ws)
                }
                is ServerMessage.Snapshot -> synchronized(lock) { if (run == mine) _snapshot.value = msg }
                is ServerMessage.Result -> msg.id?.let { inFlight[it] }?.reply?.complete(msg)
                // A skin reply carries no `result`; it still settles the request that asked for it.
                is ServerMessage.Skin -> {
                    msg.id?.let { inFlight[it] }?.reply?.complete(ServerMessage.Result(msg.id, true))
                    msg.id?.let { skinsInFlight[it] }?.reply?.complete(msg)
                }
                else -> Unit
            }
        }
        val current = synchronized(lock) { (run == mine).also { if (it) socket = link.ws } }
        try {
            if (!current) return End.Dropped(null)
            return link.ended.await()
        } finally {
            link.ws.cancel()
            synchronized(lock) { if (socket === link.ws) socket = null }
            // Only what went out on this connection: a request on a newer one is answered there.
            val gone = failure(null, "未连接")
            inFlight.values.forEach { if (it.ws === link.ws) it.reply.complete(gone) }
            skinsInFlight.values.forEach { if (it.ws === link.ws) it.reply.complete(null) }
        }
    }

    private sealed interface End {
        data class Dropped(val cause: Throwable?) : End
        data class Denied(val reason: DenyReason) : End
    }

    private class Link(val ws: WebSocket, val ended: CompletableDeferred<End>)

    /** Opens the socket and sends [first] as soon as it is up. `denied` ends the link; other frames go to [onMessage]. */
    private fun open(
        client: OkHttpClient,
        host: String,
        port: Int,
        first: ClientMessage,
        onOpen: () -> Unit = {},
        onMessage: (WebSocket, ServerMessage) -> Unit,
    ): Link {
        val ended = CompletableDeferred<End>()
        val url = HttpUrl.Builder().scheme("https").host(host).port(port).build()
        val ws = client.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                onOpen()
                webSocket.send(encode(first))
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                when (val msg = decodeServer(text)) {
                    null -> Unit
                    is ServerMessage.Denied -> ended.complete(End.Denied(msg.reason))
                    else -> onMessage(webSocket, msg)
                }
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(code, null)
                ended.complete(End.Dropped(null))
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                ended.complete(End.Dropped(null))
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                ended.complete(End.Dropped(t))
            }
        })
        return Link(ws, ended)
    }

    private fun failure(id: String?, message: String) =
        ServerMessage.Result(id, ok = false, reason = ResultReason.unknown, message = message)

    private fun deniedText(reason: DenyReason) = when (reason) {
        DenyReason.badToken -> "这台手机已不在电脑的配对列表里，请重新配对"
        DenyReason.protocol -> "协议版本不匹配，请更新 Critter"
        DenyReason.badCode, DenyReason.rejected -> "配对被拒绝"
        DenyReason.unknown -> "连接被电脑拒绝"
    }
}
