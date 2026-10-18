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
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import local.critter.core.net.BridgeClient
import local.critter.core.net.ConnState
import local.critter.core.net.Credentials
import local.critter.core.net.Endpoint
import local.critter.core.protocol.AnswerPayload
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

    private val answering = ConcurrentHashMap.newKeySet<String>()
    private val skinsAsked = ConcurrentHashMap.newKeySet<String>()
    private var client: BridgeClient? = null
    private var clientJob: Job? = null
    @Volatile private var boardVisible = false

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

    /** The board is open: ping every 30 s; otherwise every 3 minutes (spec §8.3). */
    fun boardVisible(visible: Boolean) {
        boardVisible = visible
        client?.setPingInterval(pingInterval())
    }

    private fun pingInterval() = if (boardVisible) 30_000L else 180_000L

    private fun onSnapshot(body: SnapshotBody) {
        val now = System.currentTimeMillis()
        body.sessions.mapTo(HashSet()) { it.skin }.forEach { name -> scope.launch { skinManifest(name) } }
        _snapshot.value = body
        _lastUpdated.value = now
        _live.value = body
        cache.save(body, now)
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

    /** Pairs with the Mac in [uri]; true once approved on the Mac and stored. Progress is in [pairState]. */
    suspend fun pair(uri: PairingUri): Boolean {
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
        pairingStore.clear()
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
}
