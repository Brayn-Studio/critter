package local.critter.phone.board

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.BatteryManager
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import local.critter.core.board.BoardTrigger
import local.critter.core.board.BoardTrigger.Action
import local.critter.phone.ui.board.BoardActivity

/**
 * Owned by the bridge service: opens [BoardActivity] when the phone charges lying in landscape and closes it
 * again (spec §8.6). The decisions are [BoardTrigger]'s; this class only feeds it the charger, the screen and
 * the gravity sensor, which is registered only while charging with the screen on, and carries out what it says.
 * Everything runs on the main thread.
 */
class BoardTriggerService(private val context: Context, private val enabled: () -> Boolean) {
    private val trigger = BoardTrigger()
    private val still = BoardTrigger.Stillness()
    private val handler = Handler(Looper.getMainLooper())
    private val sensors = context.getSystemService(SensorManager::class.java)
    private var started = false
    private var listening = false
    private var scheduledAt: Long? = null

    private val tick = Runnable {
        scheduledAt = null
        perform(trigger.onTick(now()))
        update()
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_POWER_CONNECTED -> perform(trigger.onPower(true, now()))
                Intent.ACTION_POWER_DISCONNECTED -> perform(trigger.onPower(false, now()))
                // No readings arrive with the screen off, and the board must never light a dark screen.
                Intent.ACTION_SCREEN_ON -> perform(trigger.onScreen(true, now()))
                Intent.ACTION_SCREEN_OFF -> perform(trigger.onScreen(false, now()))
            }
            update()
        }
    }

    private val sensorListener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            val (x, y, z) = event.values
            val t = now()
            val isStill = still.add(t, x, y, z)
            perform(trigger.onOrientation(BoardTrigger.poseOf(x, y, z), isStill, t))
            update()
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
    }

    fun start() {
        if (started) return
        started = true
        current = this
        trigger.autoOpen = enabled()
        trigger.onBoardShown(liveBoards > 0)
        // Dynamic registration: ACTION_POWER_* and ACTION_SCREEN_* cannot be declared in the manifest. The sticky
        // battery broadcast and the power manager give the state right now.
        ContextCompat.registerReceiver(
            context, receiver,
            IntentFilter().apply {
                addAction(Intent.ACTION_POWER_CONNECTED)
                addAction(Intent.ACTION_POWER_DISCONNECTED)
                addAction(Intent.ACTION_SCREEN_ON)
                addAction(Intent.ACTION_SCREEN_OFF)
            },
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        val t = now()
        trigger.onScreen(context.getSystemService(PowerManager::class.java).isInteractive, t)
        perform(trigger.onPower(isCharging(context), t))
        update()
    }

    fun stop() {
        if (!started) return
        started = false
        if (current === this) current = null
        context.unregisterReceiver(receiver)
        handler.removeCallbacks(tick)
        scheduledAt = null
        unlisten()
    }

    /** The "open by itself" setting may have changed. */
    fun settingsChanged() {
        if (!started) return
        trigger.autoOpen = enabled()
        update()
    }

    private fun boardShown(shown: Boolean) {
        trigger.onBoardShown(shown)
        update()
    }

    private fun manualExit() {
        trigger.onManualExit(now())
        update()
    }

    private fun perform(action: Action) {
        when (action) {
            Action.Open -> open()
            Action.Close -> context.sendBroadcast(Intent(ACTION_CLOSE_BOARD).setPackage(context.packageName))
            Action.None -> Unit
        }
    }

    /**
     * Starting an activity from the background needs "display over other apps"; vivo and Xiaomi also need their
     * "background pop-up" switch, and without it the start fails silently. Either way the trigger stops asking for
     * this charge: a missing permission up front, a silent refusal when the board is not up 2 s later.
     */
    private fun open() {
        if (!Settings.canDrawOverlays(context)) {
            trigger.onOpenFailed()
            return
        }
        try {
            context.startActivity(BoardActivity.intent(context, auto = true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: RuntimeException) {
            Log.w(TAG, "could not open the board", e)
            trigger.onOpenFailed()
        }
    }

    /** Sensor on or off, and the timer re-aimed, after anything the trigger was told. */
    private fun update() {
        if (!started) return
        if (trigger.sensorWanted) listen() else unlisten()
        reschedule()
    }

    private fun listen() {
        if (listening) return
        val sensor = sensors.getDefaultSensor(Sensor.TYPE_GRAVITY)
            ?: sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) ?: return
        still.clear()
        listening = sensors.registerListener(sensorListener, sensor, SensorManager.SENSOR_DELAY_NORMAL, 500_000, handler)
    }

    private fun unlisten() {
        if (!listening) return
        sensors.unregisterListener(sensorListener)
        listening = false
    }

    private fun reschedule() {
        val deadline = trigger.nextDeadline()
        if (deadline == scheduledAt) return
        handler.removeCallbacks(tick)
        scheduledAt = deadline
        if (deadline != null) handler.postDelayed(tick, (deadline - now()).coerceAtLeast(0))
    }

    private fun now() = SystemClock.elapsedRealtime()

    companion object {
        private const val TAG = "BoardTrigger"

        /** Sent inside the app to make a board that opened itself finish. */
        const val ACTION_CLOSE_BOARD = "local.critter.phone.CLOSE_BOARD"

        @Volatile private var current: BoardTriggerService? = null

        /** Boards alive right now, created and not yet destroyed (main thread only). */
        private var liveBoards = 0

        /** Whether the charger is plugged in, from the sticky battery broadcast. */
        fun isCharging(context: Context): Boolean {
            val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            return (battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
        }

        /**
         * A board was created ([shown] true) or destroyed (called from [BoardActivity] on the main thread). Only
         * its destruction counts as gone: a board whose screen went off is still there.
         */
        fun boardShown(shown: Boolean) {
            liveBoards = (liveBoards + if (shown) 1 else -1).coerceAtLeast(0)
            current?.boardShown(liveBoards > 0)
        }

        /** The user left the board by hand: it stays away until the charger is plugged in again. */
        fun manualExit() {
            current?.manualExit()
        }
    }
}
