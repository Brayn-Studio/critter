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
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import local.critter.core.board.BoardTrigger
import local.critter.core.board.BoardTrigger.Action
import local.critter.phone.ui.board.BoardActivity

/**
 * Owned by the bridge service: opens [BoardActivity] when the phone charges lying in landscape and closes it
 * again (spec §8.6). The decisions are [BoardTrigger]'s; this class only feeds it the charger and the gravity
 * sensor, which is registered only while charging, and carries out what it says. Everything runs on the main thread.
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
        reschedule()
    }

    private val powerReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            onPower(intent.action == Intent.ACTION_POWER_CONNECTED)
        }
    }

    private val sensorListener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            val (x, y, z) = event.values
            val t = now()
            val isStill = still.add(t, x, y, z)
            val landscape = BoardTrigger.isLandscape(x, y, z)
            // Automatic opening can be switched off in the settings; the board closing logic still runs.
            perform(trigger.onOrientation(landscape, isStill, t), allowOpen = enabled())
            reschedule()
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
    }

    fun start() {
        if (started) return
        started = true
        current = this
        // Dynamic registration: ACTION_POWER_* cannot be declared in the manifest. The sticky battery broadcast
        // gives the state right now.
        ContextCompat.registerReceiver(
            context, powerReceiver,
            IntentFilter().apply {
                addAction(Intent.ACTION_POWER_CONNECTED)
                addAction(Intent.ACTION_POWER_DISCONNECTED)
            },
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        onPower((battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0)
    }

    fun stop() {
        if (!started) return
        started = false
        if (current === this) current = null
        context.unregisterReceiver(powerReceiver)
        handler.removeCallbacks(tick)
        scheduledAt = null
        unlisten()
    }

    private fun onPower(charging: Boolean) {
        perform(trigger.onPower(charging, now()))
        syncSensor()
        reschedule()
    }

    private fun boardShown(shown: Boolean) {
        trigger.onBoardShown(shown)
        reschedule()
    }

    private fun manualExit() {
        trigger.onManualExit(now())
        reschedule()
    }

    private fun perform(action: Action, allowOpen: Boolean = true) {
        when (action) {
            Action.Open -> if (allowOpen && enabled()) {
                try {
                    context.startActivity(
                        Intent(context, BoardActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                } catch (e: RuntimeException) {
                    Log.w(TAG, "could not open the board", e)
                }
            }
            Action.Close -> context.sendBroadcast(Intent(ACTION_CLOSE_BOARD).setPackage(context.packageName))
            Action.None -> Unit
        }
    }

    private fun syncSensor() {
        if (trigger.sensorWanted) listen() else unlisten()
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

        /** The board came up or went away (called from [BoardActivity] on the main thread). */
        fun boardShown(shown: Boolean) {
            current?.boardShown(shown)
        }

        /** The user left the board by hand: it stays away until the charger is plugged in again. */
        fun manualExit() {
            current?.manualExit()
        }
    }
}
