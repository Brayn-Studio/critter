package local.critter.phone.bridge

import android.app.Application
import android.content.Context
import android.content.pm.ApplicationInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import local.critter.phone.critter.MotionPrefs
import local.critter.core.logic.AlertTracker
import local.critter.core.net.BridgeClient
import local.critter.core.net.ConnState
import local.critter.core.net.Credentials
import local.critter.core.net.Endpoint
import local.critter.core.net.PairFailure
import local.critter.core.net.PairResult
import local.critter.core.net.PrivateNetwork
import local.critter.core.protocol.AnswerPayload
import local.critter.core.protocol.BridgePending
import local.critter.core.protocol.ClientMessage
import local.critter.core.protocol.PairingUri
import local.critter.core.protocol.ResultReason
import local.critter.core.protocol.ServerMessage
import local.critter.core.protocol.SnapshotBody
import local.critter.phone.critter.SkinStore
import local.critter.phone.data.Pairing
import local.critter.phone.data.PairingStore
import local.critter.phone.data.SettingsStore
import local.critter.phone.data.SnapshotCache
import local.critter.phone.service.Alerts
import local.critter.phone.service.BridgeService
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap

/**
 * The one place the rest of the app talks to the Mac through. The service owns the connection's lifetime
 * ([startClient]/[stopClient]); screens only read flows and send commands.
 */
class BridgeRepository(private val app: Application) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /**
     * Writes to the pairing and the snapshot cache, off the main thread and one at a time, in the order they were
     * asked for (an unpair's delete after the last cache write, a new pairing's save after the delete). Only the
     * first reads stay on the main thread, in the constructor: a few hundred bytes the first frame needs.
     */
    private val disk = Dispatchers.IO.limitedParallelism(1)
    private val connectivity = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    val pairingStore = PairingStore(app)
    val settingsStore = SettingsStore(app)
    val nsd = NsdLocator(app)
    val skins = SkinStore(app)
    private val cache = SnapshotCache(app)

    private val _pairing = MutableStateFlow(pairingStore.load())
    /** The stored pairing; null until paired. */
    val pairing: StateFlow<Pairing?> = _pairing.asStateFlow()

    private val _state = MutableStateFlow<ConnState>(ConnState.Idle)
    val state: StateFlow<ConnState> = _state.asStateFlow()

    private val _pairState = MutableStateFlow<ConnState>(ConnState.Idle)
    /** Progress of a pairing attempt in [pair]: Connecting, AwaitingApproval, then back to Idle. */
    val pairState: StateFlow<ConnState> = _pairState.asStateFlow()

    private val cached = cache.load()
    private val _snapshot = MutableStateFlow(cached?.first)
    /** The latest snapshot; while offline, the last one received (possibly from a previous run). */
    val snapshot: StateFlow<SnapshotBody?> = _snapshot.asStateFlow()

    private val _lastUpdated = MutableStateFlow(cached?.second)
    val lastUpdated: StateFlow<Long?> = _lastUpdated.asStateFlow()

    private val _live = MutableStateFlow<SnapshotBody?>(null)
    /** The latest snapshot of the current connection only: null whenever not connected. Drives alerts. */
    val live: StateFlow<SnapshotBody?> = _live.asStateFlow()

    /** What has been alerted already, across reconnects (used by the service on its main thread). */
    val alertTracker = AlertTracker()

    private val answering = InFlight()
    private val skinsAsked = ConcurrentHashMap.newKeySet<String>()
    @Volatile private var client: BridgeClient? = null
    private var clientJob: Job? = null
    private val boards = BoardPresence()
    private val _boardOnScreen = MutableStateFlow(false)

    /** The board is on screen (started): the floating pile hides meanwhile (design §8.4). */
    val boardOnScreen: StateFlow<Boolean> = _boardOnScreen.asStateFlow()

    /** The newest snapshot not yet written to [cache], and when the cache was last written (see [onSnapshot]). */
    private var unsaved: Pair<SnapshotBody, Long>? = null
    private var cacheSavedAt = 0L

    init {
        // The phone's own skin and the reduce-motion switch follow the settings, from the first frame on.
        val first = settingsStore.settings.value
        skins.setForced(first.skinOverride)
        skins.setClockSkin(cached?.first?.prefs?.skin)
        MotionPrefs.manual = first.reduceMotion
        scope.launch {
            settingsStore.settings.collect {
                skins.setForced(it.skinOverride)
                MotionPrefs.manual = it.reduceMotion
            }
        }
    }

    // --- connection lifetime (called by BridgeService) ------------------------------------------

    @Synchronized
    fun startClient() {
        if (client != null) return
        val p = _pairing.value ?: return
        val c = BridgeClient(
            scope = scope,
            endpoint = object : Endpoint {
                override suspend fun resolve() = resolveAddress()
            },
            fingerprint = p.fingerprint,
            credentials = { _pairing.value?.let { Credentials(it.deviceId, it.token) } },
            requestTimeoutMs = REQUEST_TIMEOUT_MS,
        )
        c.setPingInterval(pingInterval())
        client = c
        clientJob = scope.launch {
            launch {
                c.state.collect { s ->
                    _state.value = s
                    if (s !is ConnState.Connected) {
                        _live.value = null
                        skinsAsked.clear()
                        flushCacheSoon()
                    }
                }
            }
            launch {
                c.snapshot.filterNotNull().collect { if (!holdingForDebug) onSnapshot(it.body) }
            }
        }
        c.start()
    }

    @Synchronized
    fun stopClient() {
        flushCacheSoon()
        clientJob?.cancel()
        clientJob = null
        client?.close()
        client = null
        _state.value = ConnState.Idle
        _live.value = null
    }

    fun reconnectNow() {
        client?.reconnectNow()
    }

    /**
     * Brings the connection back if it is down. A notification button or a sheet may be the first thing a process
     * runs after vivo killed or froze it, with no client at all: this starts the service (a notification tap is a
     * foreground-service start exemption), starts the client in case the service is not up yet, and skips the
     * backoff wait if it is offline. A connection that is up, or being made, is left alone.
     */
    fun ensureConnected() {
        BridgeService.sync(app, this)
        if (!BridgeService.shouldRun(this)) return
        startClient()
        // The client's own state, not the mirror in [state], which lags: reconnectNow drops a connected client.
        client?.let { if (it.state.value is ConnState.Offline) it.reconnectNow() }
    }

    /** What [awaitRequest] found. */
    sealed interface LiveRequest {
        data class Found(val request: BridgePending) : LiveRequest

        /** Connected, and the Mac no longer lists it: answered elsewhere, or expired. */
        data object Gone : LiveRequest

        /** No connection came up in time. */
        data object Offline : LiveRequest
    }

    /**
     * Waits up to [timeoutMs] for a live connection (its snapshot, never the cached one) and looks [requestId] up
     * in it (spec §8.5: only a request the Mac still lists may be answered).
     */
    suspend fun awaitRequest(requestId: String, timeoutMs: Long = LIVE_WAIT_MS): LiveRequest {
        val body = withTimeoutOrNull(timeoutMs) {
            combine(state, live) { s, l -> if (s is ConnState.Connected) l else null }.filterNotNull().first()
        } ?: return LiveRequest.Offline
        val request = body.pending.firstOrNull { it.requestId == requestId } ?: return LiveRequest.Gone
        return LiveRequest.Found(request)
    }

    /**
     * For a caller with no screen (a notification button): brings the connection back, waits for it to list
     * [requestId], and answers with what [payloadFor] makes of the request (null: cannot be answered this way,
     * reason `invalid`). A request that is gone gives `resolved`; no connection gives `unknown` "没连上电脑".
     *
     * If the answer failed on the phone's side (reason `unknown`: the connection dropped under it, or no reply in
     * time, which drops it), it tries once more, on a new connection: it first waits for the failed one to leave
     * [ConnState.Connected], so the retry never goes out on it, nor is checked against its last snapshot. The Mac
     * only accepts an answer to a request it still lists, so a second one for a request the first already settled
     * comes back `resolved`. If the connection stays up (an `unknown` the Mac itself sent: a reason this phone does
     * not know), there is no retry: the Mac's result is the answer.
     *
     * All of it takes at most [ANSWER_DEADLINE_MS] (the request timeout plus [LIVE_WAIT_MS], about 18 s): on a
     * connection that looks up but is dead, the first answer times out after 10 s, which leaves 8 s for a new
     * connection and the second one. Past that, `unknown` as well.
     */
    suspend fun answerWhenLive(requestId: String, payloadFor: (BridgePending) -> AnswerPayload?): ServerMessage.Result {
        var sending = false
        suspend fun attempts(): ServerMessage.Result {
            var failed: ServerMessage.Result? = null
            for (attempt in 0..1) {
                if (failed != null) {
                    // A failure on the phone's side takes the connection down at once (the client drops it on a
                    // timeout, or it had ended), but the state leaves Connected a moment later: wait for that first.
                    // Still connected after the grace, the `unknown` came from the Mac itself (a reason this phone
                    // does not know): that is the answer, with the Mac's own words.
                    withTimeoutOrNull(LINK_DROP_GRACE_MS) { state.first { it !is ConnState.Connected } } ?: return failed
                }
                ensureConnected()
                when (val found = awaitRequest(requestId)) {
                    LiveRequest.Offline -> return failure(ResultReason.unknown, "没连上电脑，没有发送")
                    LiveRequest.Gone -> return failure(ResultReason.resolved, "已在电脑上处理")
                    is LiveRequest.Found -> {
                        val payload = payloadFor(found.request) ?: return failure(ResultReason.invalid, "要打开卡片回答")
                        sending = true
                        val result = answer(requestId, payload)
                        sending = false
                        // The card's answer going out meanwhile is not a broken connection: nothing to retry.
                        val localFailure = !result.ok && result.reason == ResultReason.unknown &&
                            !InFlight.isAlreadySending(result)
                        if (!localFailure || attempt == 1) return result
                        failed = result
                    }
                }
            }
            return failure(ResultReason.unknown, "没有发送出去")
        }
        return withTimeoutOrNull(ANSWER_DEADLINE_MS) { attempts() }
            ?: failure(ResultReason.unknown, if (sending) "没有收到电脑的回复" else "没连上电脑，没有发送")
    }

    /**
     * A board started ([visible]) or stopped; each board reports both, once. While one is open: ping every 30 s,
     * otherwise every 3 minutes (spec §8.3). Also [boardOnScreen].
     */
    fun boardVisible(visible: Boolean) {
        if (visible) boards.started() else boards.stopped()
        _boardOnScreen.value = boards.onScreen
        client?.setPingInterval(pingInterval())
    }

    private fun pingInterval() = if (_boardOnScreen.value) 30_000L else 180_000L

    private fun onSnapshot(body: SnapshotBody) {
        val now = System.currentTimeMillis()
        // The Mac's default skin too: its tick runs the clock, even when no session wears it ("随机宠物").
        (body.sessions.mapTo(HashSet()) { it.skin } + body.prefs.skin)
            .filter { it !in skinsAsked && !skins.isBundled(it) && skins.pushed(it) == null }
            .forEach { name -> scope.launch { skinManifest(name) } }
        skins.setClockSkin(body.prefs.skin)
        _snapshot.value = body
        _lastUpdated.value = now
        _live.value = body
        // The cache is only read while offline: a write at most every 30 s, and the newest one when the
        // connection ends, rather than a file write on every snapshot.
        synchronized(cache) {
            unsaved = body to now
            if (now - cacheSavedAt < CACHE_EVERY_MS) return
        }
        flushCacheSoon()
    }

    /** Writes the newest unsaved snapshot to the cache, on [disk]. */
    private fun flushCacheSoon() {
        scope.launch(disk) { flushCache() }
    }

    private fun flushCache() {
        synchronized(cache) {
            val (body, at) = unsaved ?: return
            unsaved = null
            cacheSavedAt = at
            cache.save(body, at)
        }
    }

    /** A debuggable build: the debug hooks below do nothing in a release one. */
    private val debuggable = app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0

    /** Debug builds only (DebugSnapshotReceiver): shows [body] as if the Mac had sent it. */
    fun injectSnapshotForDebug(body: SnapshotBody) {
        if (!debuggable) return
        onSnapshot(body)
        _live.value = body
    }

    /** Debug builds only (DebugSnapshotReceiver's `hold`): while set, the Mac's snapshots are not shown. */
    @Volatile
    private var holdingForDebug = false

    fun holdForDebug(hold: Boolean) {
        if (!debuggable) return
        holdingForDebug = hold
        if (!hold) client?.snapshot?.value?.let { onSnapshot(it.body) }
    }

    // --- commands -----------------------------------------------------------------------------

    /**
     * Sends the answer to [requestId]. A second call for the same request while the first is in flight
     * (say, a notification button and the card tapped together) is not sent: it gets [InFlight.alreadySending].
     */
    suspend fun answer(requestId: String, payload: AnswerPayload): ServerMessage.Result {
        if (!answering.start(requestId)) return InFlight.alreadySending()
        try {
            val c = client ?: return failure(ResultReason.unknown, "未连接")
            return c.request(ClientMessage.Answer(null, requestId, payload))
        } finally {
            answering.finish(requestId)
        }
    }

    /**
     * Allows or denies a lone permission [request] from a screen's own buttons (the home list), drafted like the
     * answer card does it (`AnswerDraft`). It is sent in this repository's scope, so leaving the screen does not
     * cancel it; [onResult] runs on the main thread.
     */
    fun answerPermission(request: BridgePending, allow: Boolean, onResult: (ServerMessage.Result) -> Unit) {
        val draft = local.critter.core.logic.AnswerDraft(request)
        if (allow) draft.allow() else draft.deny(null)
        val payload = draft.payload()
        scope.launch {
            val result = if (payload == null) failure(ResultReason.invalid, "要打开卡片回答") else answer(request.requestId, payload)
            withContext(Dispatchers.Main) { onResult(result) }
        }
    }

    /**
     * The manifest JSON for skin [name]: a bundled skin straight from assets; otherwise the one the Mac sent
     * before, or else asked for now with a `skin` request, remembered in memory and in the app's private
     * `skins/<name>.json` (this is what feeds [SkinStore.library]). Null if the Mac has no such skin or is out
     * of reach; the app then draws clawd. A name is only asked for once per connection.
     */
    suspend fun skinManifest(name: String): String? {
        skins.bundled(name)?.let { return it }
        skins.pushed(name)?.let { return it }
        val c = client ?: return null
        if (!skinsAsked.add(name)) return null
        val manifest = c.requestSkin(name)?.manifest?.toString()
        if (manifest == null || !skins.put(name, manifest)) {
            // Asked again after the next reconnect, not on every snapshot.
            return null
        }
        return manifest
    }

    /** Tells the Mac a finished session was looked at, without waiting for the reply. */
    fun markSeen(sessionId: String) {
        scope.launch { seen(sessionId) }
    }

    suspend fun seen(sessionId: String) {
        client?.request(ClientMessage.Seen(null, sessionId))
    }

    suspend fun say(sessionId: String, text: String): ServerMessage.Result {
        val c = client ?: return failure(ResultReason.unknown, "未连接")
        return c.request(ClientMessage.Say(null, sessionId, text))
    }

    suspend fun interrupt(sessionId: String): ServerMessage.Result {
        val c = client ?: return failure(ResultReason.unknown, "未连接，没有发送停止请求")
        return c.request(ClientMessage.Interrupt(null, sessionId))
    }

    private fun failure(reason: ResultReason, message: String) =
        ServerMessage.Result(id = null, ok = false, reason = reason, message = message)

    // --- pairing --------------------------------------------------------------------------------

    /**
     * Pairs with the Mac in [uri]; null once approved on the Mac and stored, otherwise why not. Progress is in
     * [pairState]. A host outside the local network is refused before anything is sent, as [PairFailure.Unreachable].
     */
    suspend fun pair(uri: PairingUri): PairFailure? {
        if (!PrivateNetwork.isAllowed(uri.host)) return PairFailure.Unreachable
        stopClient()
        val temp = BridgeClient(scope, object : Endpoint {
            override suspend fun resolve(): Pair<String, Int>? = null
        }, uri.fingerprint, { null })
        val progress = scope.launch { temp.state.collect { _pairState.value = it } }
        var success = false
        try {
            val paired = when (val result = temp.pair(uri, Build.MODEL ?: "Android")) {
                is PairResult.Failed -> return result.why
                is PairResult.Paired -> result.paired
            }
            val p = Pairing(
                host = uri.host,
                port = uri.port,
                fingerprint = uri.fingerprint,
                macName = paired.macName.ifEmpty { uri.name },
                deviceId = paired.deviceId,
                token = paired.token,
            )
            withContext(disk) { pairingStore.save(p) }
            _pairing.value = p
            BridgeService.sync(app, this)
            // A running service only re-delivers onStartCommand; the client must be restarted here. Restarted, not
            // just started: one may have come up for the old pairing meanwhile (the app came back to the front
            // while the Mac was asking), pinned to the old certificate. Not with "保持后台连接" off: then there is
            // no service, and no connection without it.
            stopClient()
            if (BridgeService.shouldRun(this)) startClient()
            success = true
            return null
        } finally {
            progress.cancel()
            temp.close()
            _pairState.value = ConnState.Idle
            // A failed re-pairing leaves the old pairing in place: bring its connection back.
            if (!success && BridgeService.shouldRun(this)) startClient()
        }
    }

    /**
     * Forgets the Mac, in this repository's scope (leaving the screen does not cut it short), then runs [onDone] on
     * the main thread. The pairing and the cache are deleted from disk before anything reports "unpaired": a process
     * killed meanwhile comes back paired as it was, never unpaired on screen yet still paired on disk.
     */
    fun unpair(onDone: () -> Unit = {}) {
        stopClient()
        Alerts.withdrawAll(app, results = true)
        synchronized(cache) { unsaved = null }
        // After stopClient's last cache write, and before any new pairing's save: [disk] keeps the order.
        scope.launch(disk) {
            pairingStore.clear()
            cache.clear()
            _pairing.value = null
            _snapshot.value = null
            _lastUpdated.value = null
            withContext(Dispatchers.Main) {
                // Also stops a client that came up meanwhile for the pairing that is gone now.
                BridgeService.sync(app, this@BridgeRepository)
                onDone()
            }
        }
    }

    // --- finding the Mac ------------------------------------------------------------------------

    /**
     * Where to connect now: the last good address if it answers, otherwise whatever NSD finds for the
     * paired Mac's name (its IP may have changed; the pinned fingerprint is unchanged). Off Wi-Fi there is
     * nothing to try, except 127.0.0.1, which is `adb reverse` during development (spec §8.3).
     */
    private suspend fun resolveAddress(): Pair<String, Int>? = withContext(Dispatchers.IO) {
        val p = _pairing.value ?: return@withContext null
        val loopback = p.host == "127.0.0.1"
        if (loopback) return@withContext p.host to p.port
        if (!onWifi()) return@withContext null
        if (reachable(p.host, p.port)) return@withContext p.host to p.port
        val found = nsd.find(p.macName) ?: return@withContext null
        val moved = p.copy(host = found.first, port = found.second)
        // Unpaired or paired anew while NSD was looking: that pairing stays, the found address is not saved over it.
        if (!_pairing.compareAndSet(p, moved)) return@withContext null
        withContext(disk) { if (_pairing.value == moved) pairingStore.save(moved) }
        found
    }

    private fun onWifi(): Boolean {
        val caps = connectivity.getNetworkCapabilities(connectivity.activeNetwork) ?: return false
        return caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
    }

    private fun reachable(host: String, port: Int): Boolean = try {
        Socket().use { it.connect(InetSocketAddress(host, port), 1_500) }
        true
    } catch (_: Exception) {
        false
    }

    companion object {
        /** How long a notification button or a sheet waits for the connection to come back. */
        const val LIVE_WAIT_MS = 8_000L

        /** How long the Mac gets to reply to a command before the connection counts as broken ([BridgeClient]). */
        const val REQUEST_TIMEOUT_MS = 10_000L

        /** The longest a notification button's answer takes, retry included ([answerWhenLive]). */
        const val ANSWER_DEADLINE_MS = REQUEST_TIMEOUT_MS + LIVE_WAIT_MS

        /**
         * How long a failed answer's connection gets to leave Connected before the failure counts as the Mac's own
         * ([answerWhenLive]). A dropped socket is reported within milliseconds.
         */
        private const val LINK_DROP_GRACE_MS = 2_000L

        /** The snapshot cache is written at most this often while connected. */
        private const val CACHE_EVERY_MS = 30_000L
    }
}
