package local.critter.phone.bridge

import android.app.Application
import android.content.Context
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

    private val answering = ConcurrentHashMap.newKeySet<String>()
    private val skinsAsked = ConcurrentHashMap.newKeySet<String>()
    private var client: BridgeClient? = null
    private var clientJob: Job? = null
    @Volatile private var boardVisible = false

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
                        flushCache()
                    }
                }
            }
            launch {
                c.snapshot.filterNotNull().collect { onSnapshot(it.body) }
            }
        }
        c.start()
    }

    @Synchronized
    fun stopClient() {
        flushCache()
        clientJob?.cancel()
        clientJob = null
        client?.stop()
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
     * backoff wait. A connection that is up is left alone.
     */
    fun ensureConnected() {
        BridgeService.sync(app, this)
        if (!BridgeService.shouldRun(this)) return
        startClient()
        if (_state.value !is ConnState.Connected) client?.reconnectNow()
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
     * reason `invalid`). If the answer failed on the phone's side (the connection dropped under it, or no reply in
     * time: reason `unknown`), it tries once more; the Mac only accepts an answer to a request it still lists, so a
     * second one for a request the first already settled comes back `resolved`. A request that is gone gives
     * `resolved`; no connection gives `unknown` "没连上电脑".
     */
    suspend fun answerWhenLive(requestId: String, payloadFor: (BridgePending) -> AnswerPayload?): ServerMessage.Result {
        for (attempt in 0..1) {
            ensureConnected()
            when (val found = awaitRequest(requestId)) {
                LiveRequest.Offline -> return failure(ResultReason.unknown, "没连上电脑，没有发送")
                LiveRequest.Gone -> return failure(ResultReason.resolved, "已在电脑上处理")
                is LiveRequest.Found -> {
                    val payload = payloadFor(found.request) ?: return failure(ResultReason.invalid, "要打开卡片回答")
                    val result = answer(requestId, payload)
                    // Checking the state here would race: the socket's end is reported before the state leaves Connected.
                    val localFailure = !result.ok && result.reason == ResultReason.unknown
                    if (!localFailure || attempt == 1) return result
                }
            }
        }
        return failure(ResultReason.unknown, "没有发送出去")
    }

    /** The board is open: ping every 30 s; otherwise every 3 minutes (spec §8.3). */
    fun boardVisible(visible: Boolean) {
        boardVisible = visible
        client?.setPingInterval(pingInterval())
    }

    private fun pingInterval() = if (boardVisible) 30_000L else 180_000L

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
        flushCache()
    }

    private fun flushCache() {
        synchronized(cache) {
            val (body, at) = unsaved ?: return
            unsaved = null
            cacheSavedAt = at
            cache.save(body, at)
        }
    }

    /** Debug builds only (DebugSnapshotReceiver): shows [body] as if the Mac had sent it. */
    fun injectSnapshotForDebug(body: SnapshotBody) {
        onSnapshot(body)
        _live.value = body
    }

    // --- commands -----------------------------------------------------------------------------

    /**
     * Sends the answer to [requestId]. A second call for the same request while the first is in flight
     * (say, a notification button and the card tapped together) answers `resolved` instead of sending twice.
     */
    suspend fun answer(requestId: String, payload: AnswerPayload): ServerMessage.Result {
        if (!answering.add(requestId)) return failure(ResultReason.resolved, "已在电脑上处理")
        try {
            val c = client ?: return failure(ResultReason.unknown, "未连接")
            return c.request(ClientMessage.Answer(null, requestId, payload))
        } finally {
            answering.remove(requestId)
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

    private fun failure(reason: ResultReason, message: String) =
        ServerMessage.Result(id = null, ok = false, reason = reason, message = message)

    // --- pairing --------------------------------------------------------------------------------

    /**
     * Pairs with the Mac in [uri]; true once approved on the Mac and stored. Progress is in [pairState]. A host
     * outside the local network is refused before anything is sent (the screen says why).
     */
    suspend fun pair(uri: PairingUri): Boolean {
        if (!PrivateNetwork.isAllowed(uri.host)) return false
        stopClient()
        val temp = BridgeClient(scope, object : Endpoint {
            override suspend fun resolve(): Pair<String, Int>? = null
        }, uri.fingerprint, { null })
        val progress = scope.launch { temp.state.collect { _pairState.value = it } }
        var success = false
        try {
            val paired = temp.pair(uri, Build.MODEL ?: "Android") ?: return false
            val p = Pairing(
                host = uri.host,
                port = uri.port,
                fingerprint = uri.fingerprint,
                macName = paired.macName.ifEmpty { uri.name },
                deviceId = paired.deviceId,
                token = paired.token,
            )
            pairingStore.save(p)
            _pairing.value = p
            BridgeService.sync(app, this)
            // A running service only re-delivers onStartCommand; the client must be restarted here (idempotent).
            // Not with "保持后台连接" off: then there is no service, and no connection without it.
            if (BridgeService.shouldRun(this)) startClient()
            success = true
            return true
        } finally {
            progress.cancel()
            _pairState.value = ConnState.Idle
            // A failed re-pairing leaves the old pairing in place: bring its connection back.
            if (!success && BridgeService.shouldRun(this)) startClient()
        }
    }

    fun unpair() {
        stopClient()
        Alerts.withdrawAll(app, results = true)
        pairingStore.clear()
        synchronized(cache) { unsaved = null }
        cache.clear()
        _pairing.value = null
        _snapshot.value = null
        _lastUpdated.value = null
        BridgeService.sync(app, this)
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
        pairingStore.save(moved)
        _pairing.value = moved
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

        /** The snapshot cache is written at most this often while connected. */
        private const val CACHE_EVERY_MS = 30_000L
    }
}
