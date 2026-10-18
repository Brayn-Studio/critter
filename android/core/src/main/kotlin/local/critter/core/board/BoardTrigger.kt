package local.critter.core.board

import kotlin.math.abs

/**
 * When the landscape board opens and closes by itself (spec §8.6): it opens once the phone has been charging,
 * lying in landscape and still for [holdMs]; it closes [unplugExitMs] after the charger is pulled, or when the
 * phone has been upright for [portraitExitMs]. A board the user closed stays closed until the next plug-in.
 *
 * Pure and single-threaded: the caller passes a monotonic clock and calls [onTick] at [nextDeadline].
 */
class BoardTrigger(
    private val holdMs: Long = 3_000,
    private val unplugExitMs: Long = 10_000,
    private val portraitExitMs: Long = 3_000,
) {
    sealed interface Action {
        data object Open : Action
        data object Close : Action
        data object None : Action
    }

    private var charging = false
    private var shown = false
    private var suppressed = false

    /** Since when the phone has been charging, landscape and still (while the board is not up). */
    private var holdSince: Long? = null

    /** Since when the phone has not been landscape (while the board is up). */
    private var uprightSince: Long? = null

    /** When the charger was pulled (while the board is up). */
    private var unpluggedAt: Long? = null

    /** The gravity sensor is only needed while charging. */
    val sensorWanted: Boolean get() = charging

    fun onPower(charging: Boolean, nowMs: Long): Action {
        if (charging == this.charging) return evaluate(nowMs)
        this.charging = charging
        if (charging) {
            // A new plug-in lifts the suppression a manual exit put on this charge.
            suppressed = false
            unpluggedAt = null
            uprightSince = null
        } else {
            holdSince = null
            if (shown) unpluggedAt = nowMs
        }
        return evaluate(nowMs)
    }

    fun onOrientation(landscape: Boolean, still: Boolean, nowMs: Long): Action {
        if (!charging) return evaluate(nowMs)
        if (shown) {
            if (landscape) uprightSince = null else if (uprightSince == null) uprightSince = nowMs
        } else if (landscape && still && !suppressed) {
            if (holdSince == null) holdSince = nowMs
        } else {
            holdSince = null
        }
        return evaluate(nowMs)
    }

    fun onTick(nowMs: Long): Action = evaluate(nowMs)

    /** The user left the board: no automatic opening until the charger is plugged in again. */
    fun onManualExit(nowMs: Long) {
        suppressed = true
        holdSince = null
        uprightSince = null
        unpluggedAt = null
    }

    fun onBoardShown(shown: Boolean) {
        this.shown = shown
        holdSince = null
        uprightSince = null
        if (!shown) unpluggedAt = null
    }

    /** The next time [onTick] has something to decide, or null. */
    fun nextDeadline(): Long? = listOfNotNull(
        holdSince?.let { it + holdMs },
        uprightSince?.let { it + portraitExitMs },
        unpluggedAt?.let { it + unplugExitMs },
    ).minOrNull()

    private fun evaluate(nowMs: Long): Action {
        val hold = holdSince
        if (hold != null && !shown && charging && !suppressed && nowMs - hold >= holdMs) {
            // Needs a fresh hold before it asks again (the system may have refused to show the board).
            holdSince = null
            return Action.Open
        }
        if (shown) {
            val upright = uprightSince
            val unplugged = unpluggedAt
            if ((upright != null && nowMs - upright >= portraitExitMs) ||
                (unplugged != null && nowMs - unplugged >= unplugExitMs)
            ) {
                uprightSince = null
                unpluggedAt = null
                return Action.Close
            }
        }
        return Action.None
    }

    /** Whether the last 1.5 s of gravity readings stayed within 0.5 m/s² on every axis. */
    class Stillness(private val windowMs: Long = 1_500, private val tolerance: Float = 0.5f) {
        private val times = ArrayDeque<Long>()
        private val xs = ArrayDeque<Float>()
        private val ys = ArrayDeque<Float>()
        private val zs = ArrayDeque<Float>()

        /** Adds a reading and says whether the phone is still. */
        fun add(nowMs: Long, x: Float, y: Float, z: Float): Boolean {
            times.addLast(nowMs); xs.addLast(x); ys.addLast(y); zs.addLast(z)
            while (times.isNotEmpty() && nowMs - times.first() >= windowMs) {
                times.removeFirst(); xs.removeFirst(); ys.removeFirst(); zs.removeFirst()
            }
            return range(xs) < tolerance && range(ys) < tolerance && range(zs) < tolerance
        }

        fun clear() {
            times.clear(); xs.clear(); ys.clear(); zs.clear()
        }

        private fun range(v: ArrayDeque<Float>): Float = (v.maxOrNull() ?: 0f) - (v.minOrNull() ?: 0f)
    }

    companion object {
        /**
         * Standing on a long edge: gravity runs along the device's short axis (|gx| > 7) and not much through the
         * screen (|gz| < 6). Flat on a table (|gz| > 9) is not landscape.
         */
        fun isLandscape(gx: Float, @Suppress("UNUSED_PARAMETER") gy: Float, gz: Float): Boolean =
            abs(gx) > 7f && abs(gz) < 6f && abs(gz) <= 9f
    }
}
