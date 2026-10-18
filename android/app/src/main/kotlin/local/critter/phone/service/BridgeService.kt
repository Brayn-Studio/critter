package local.critter.phone.service

import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.os.IBinder
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import local.critter.core.logic.AlertPlanner
import local.critter.core.logic.AlertPrefs
import local.critter.core.net.ConnState
import local.critter.core.protocol.SnapshotBody
import local.critter.phone.bridge.BridgeRepository
import local.critter.phone.board.BoardTriggerService
import local.critter.phone.overlay.OverlayController
import local.critter.phone.repository

/**
 * Keeps the connection to the Mac alive while the phone is paired and the bridge is enabled, and turns
 * snapshots into alerts. The ongoing notification is the foreground-service requirement and the status line.
 */
class BridgeService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var repo: BridgeRepository
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private lateinit var overlay: OverlayController
    private lateinit var boardTrigger: BoardTriggerService

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        repo = repository
        overlay = OverlayController(this, repo)
        boardTrigger = BoardTriggerService(this) { repo.settingsStore.settings.value.boardAutoOpen }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Must be called promptly after startForegroundService, even if we are about to stop.
        startForeground(
            Alerts.STATUS_ID,
            Alerts.statusNotification(this, "未连接", null),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
        )
        if (!shouldRun(repo)) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (networkCallback == null) run()
        syncOverlay()
        return START_STICKY
    }

    private fun run() {
        repo.startClient()
        boardTrigger.start()
        watchNetwork()

        scope.launch {
            combine(repo.state, repo.live, repo.pairing) { state, live, pairing -> Triple(state, live, pairing) }
                .collect { (state, live, pairing) ->
                    val (title, text) = statusText(state, live, pairing?.macName)
                    // Without a POST_NOTIFICATIONS grant the system drops this quietly; the service still runs.
                    getSystemService(NotificationManager::class.java)
                        .notify(Alerts.STATUS_ID, Alerts.statusNotification(this@BridgeService, title, text))
                }
        }

        scope.launch {
            var previous: SnapshotBody? = null
            repo.live.collect { body ->
                if (body == null) {
                    previous = null
                    return@collect
                }
                val s = repo.settingsStore.settings.value
                val prefs = AlertPrefs(s.vibrateOnWaiting, s.notifyDone, s.notifyError)
                val plan = AlertPlanner.plan(previous, body, prefs)
                // Notifications only when the floating pile cannot be seen (spec §8.7); the buzz stays.
                Alerts.apply(
                    this@BridgeService, plan, body,
                    canVibrate = Alerts.vibrationAllowed(this@BridgeService),
                    notify = !overlay.isVisible,
                )
                previous = body
            }
        }

        // The floating pile follows the data, the connection and the settings.
        scope.launch {
            combine(repo.snapshot, repo.state, repo.settingsStore.settings) { body, state, settings -> Triple(body, state, settings) }
                .collect { (body, state, settings) ->
                    overlay.update(body, state is ConnState.Connected, settings)
                    syncOverlay()
                }
        }

        // Stop when unpaired or switched off in settings.
        scope.launch {
            combine(repo.pairing, repo.settingsStore.settings) { p, s -> p != null && s.bridgeEnabled }
                .collect { if (!it) stopSelf() }
        }
    }

    /** Shows or hides the floating pile to match the setting and the "display over other apps" permission. */
    private fun syncOverlay() {
        if (repo.settingsStore.settings.value.overlayEnabled) overlay.show() else overlay.hide()
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        overlay.onConfigurationChanged()
    }

    private fun watchNetwork() {
        val cm = getSystemService(ConnectivityManager::class.java)
        var first = true
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                // The callback fires once on registration; that is not a change.
                if (first) {
                    first = false
                    return
                }
                repo.reconnectNow()
            }
        }
        networkCallback = cb
        cm.registerDefaultNetworkCallback(cb)
    }

    override fun onDestroy() {
        networkCallback?.let { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) }
        networkCallback = null
        scope.cancel()
        boardTrigger.stop()
        overlay.hide()
        repo.stopClient()
        super.onDestroy()
    }

    companion object {
        fun shouldRun(repo: BridgeRepository): Boolean =
            repo.pairing.value != null && repo.settingsStore.settings.value.bridgeEnabled

        /** Starts the service if it should run; stops it if not. Safe to call from the foreground or at boot. */
        fun sync(context: Context, repo: BridgeRepository) {
            val intent = Intent(context, BridgeService::class.java)
            if (shouldRun(repo)) {
                try {
                    ContextCompat.startForegroundService(context, intent)
                } catch (_: RuntimeException) {
                    // Started from the background with no exemption; it starts next time the app is opened.
                }
            } else {
                context.stopService(intent)
            }
        }

        fun statusText(state: ConnState, live: SnapshotBody?, macName: String?): Pair<String, String?> = when (state) {
            is ConnState.Connected -> "已连接 · ${live?.sessions?.size ?: 0} 个会话" to state.macName
            is ConnState.NeedsRepair -> "未连接" to state.reason
            else -> "未连接" to macName
        }
    }
}
