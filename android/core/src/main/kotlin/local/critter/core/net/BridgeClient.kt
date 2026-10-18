package local.critter.core.net

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
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
 * Not for use before [start] is called; [stop] disconnects and ends the retry loop.
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

    private var pingIntervalMs = 30_000L
    @Volatile private var http = buildHttp(fingerprint)
    @Volatile private var job: Job? = null
    @Volatile private var socket: WebSocket? = null
    @Volatile private var offlineSince: Long? = null
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private val inFlight = ConcurrentHashMap<String, CompletableDeferred<ServerMessage.Result>>()
    private val skinsInFlight = ConcurrentHashMap<String, CompletableDeferred<ServerMessage.Skin?>>()
    private val nextId = AtomicLong()

    private fun buildHttp(pin: String): OkHttpClient = PinnedTls.client(
        pin,
        OkHttpClient.Builder().pingInterval(pingIntervalMs, TimeUnit.MILLISECONDS).build(),
    )

    @Synchronized
    fun start() {
        if (job?.isActive == true) return
        job = scope.launch { runLoop() }
    }

    @Synchronized
    fun stop() {
        job?.cancel()
        job = null
        socket?.cancel()
        socket = null
        _state.value = ConnState.Idle
    }

    /** Drops the current connection (if any) and connects again without waiting out the backoff. */
    fun reconnectNow() {
        wake.trySend(Unit)
        socket?.cancel()
    }

    /** 30 s while the board is open, 3 min otherwise. The client is rebuilt, so the connection is renewed. */
    fun setPingInterval(ms: Long) {
        if (ms == pingIntervalMs) return
        pingIntervalMs = ms
        http = buildHttp(fingerprint)
        if (job?.isActive == true) reconnectNow()
    }

    /** Sends [msg] with a fresh correlation id and waits for the Mac's `result`. */
    suspend fun request(msg: ClientMessage.Command): ServerMessage.Result {
        val id = "a${nextId.incrementAndGet()}"
        val ws = socket ?: return failure(id, "未连接")
        val reply = CompletableDeferred<ServerMessage.Result>()
        inFlight[id] = reply
        try {
            if (!ws.send(encode(msg.withId(id)))) return failure(id, "未连接")
            return withTimeoutOrNull(requestTimeoutMs) { reply.await() } ?: failure(id, "超时")
        } finally {
            inFlight.remove(id)
        }
    }

    /**
     * Asks the Mac for a skin's manifest. Null if the Mac has no such skin, the connection is down or it
     * does not answer in time.
     */
    suspend fun requestSkin(name: String): ServerMessage.Skin? {
        val id = "a${nextId.incrementAndGet()}"
        val ws = socket ?: return null
        val reply = CompletableDeferred<ServerMessage.Skin?>()
        skinsInFlight[id] = reply
        try {
            if (!ws.send(encode(ClientMessage.SkinRequest(id, name)))) return null
            return withTimeoutOrNull(requestTimeoutMs) { reply.await() }
        } finally {
            skinsInFlight.remove(id)
        }
    }

    /**
     * First-time pairing over a connection pinned to the fingerprint in [uri]. Returns once the user has
     * approved on the Mac (up to [pairTimeoutMs]), or null if denied, timed out or unreachable.
     * The caller stores the returned credentials and [uri]'s fingerprint, then connects normally.
     */
    suspend fun pair(uri: PairingUri, deviceName: String): ServerMessage.Paired? {
        _state.value = ConnState.Connecting
        val paired = CompletableDeferred<ServerMessage.Paired>()
        val link = open(
            client = PinnedTls.client(uri.fingerprint, http),
            host = uri.host,
            port = uri.port,
            first = ClientMessage.Pair(uri.code, deviceName),
            onOpen = { _state.value = ConnState.AwaitingApproval },
        ) { msg -> if (msg is ServerMessage.Paired) paired.complete(msg) }
        try {
            val result = withTimeoutOrNull(pairTimeoutMs) {
                // Whichever comes first: the approval, or the connection ending (denied, refused, closed).
                val ended = CompletableDeferred<Unit>().also { gate ->
                    link.ended.invokeOnCompletion { gate.complete(Unit) }
                    paired.invokeOnCompletion { gate.complete(Unit) }
                }
                ended.await()
                if (paired.isCompleted) paired.await() else null
            }
            result?.let { _pairing.tryEmit(it) }
            return result
        } finally {
            link.ws.cancel()
            _state.value = if (job?.isActive == true) _state.value else ConnState.Idle
        }
    }

    // --- connection loop -------------------------------------------------------------------

    private suspend fun runLoop() {
        while (currentCoroutineContext().isActive) {
            val creds = credentials()
            if (creds == null) {
                _state.value = ConnState.NeedsRepair("尚未配对")
                return
            }
            _state.value = ConnState.Connecting
            wake.tryReceive()

            val end = connectOnce(creds)
            when {
                end is End.Denied -> {
                    _state.value = ConnState.NeedsRepair(deniedText(end.reason))
                    return
                }
                end is End.Dropped && end.cause.hasPinMismatch() -> {
                    _state.value = ConnState.NeedsRepair("证书指纹与配对时不一致，请重新配对")
                    return
                }
            }
            val since = offlineSince ?: clock().also { offlineSince = it }
            val delayMs = backoff.nextDelayMs()
            _state.value = ConnState.Offline(delayMs, since)
            withTimeoutOrNull(delayMs) { wake.receive() }
        }
    }

    private suspend fun connectOnce(creds: Credentials): End {
        val address = endpoint.resolve() ?: return End.Dropped(null)
        val link = open(
            client = http,
            host = address.first,
            port = address.second,
            first = ClientMessage.Hello(appName, creds.deviceId, creds.token),
        ) { msg ->
            when (msg) {
                is ServerMessage.Welcome -> {
                    backoff.reset()
                    offlineSince = null
                    _state.value = ConnState.Connected(msg.macName)
                }
                is ServerMessage.Snapshot -> _snapshot.value = msg
                is ServerMessage.Result -> msg.id?.let { inFlight[it] }?.complete(msg)
                // A skin reply carries no `result`; it still settles the request that asked for it.
                is ServerMessage.Skin -> {
                    msg.id?.let { inFlight[it] }?.complete(ServerMessage.Result(msg.id, true))
                    msg.id?.let { skinsInFlight[it] }?.complete(msg)
                }
                else -> Unit
            }
        }
        socket = link.ws
        try {
            return link.ended.await()
        } finally {
            link.ws.cancel()
            socket = null
            val gone = failure(null, "未连接")
            inFlight.values.forEach { it.complete(gone) }
            skinsInFlight.values.forEach { it.complete(null) }
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
        onMessage: (ServerMessage) -> Unit,
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
                    else -> onMessage(msg)
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

    /**
     * Looks through causes and suppressed exceptions: with several addresses to try (IPv6 then IPv4),
     * OkHttp reports the first failure and hangs the rest, such as the pin mismatch, off it as suppressed.
     */
    private fun Throwable?.hasPinMismatch(depth: Int = 0): Boolean {
        if (this == null || depth > 8) return false
        return this is PinMismatchException || cause.takeIf { it !== this }.hasPinMismatch(depth + 1) ||
            suppressed.any { it.hasPinMismatch(depth + 1) }
    }
}
