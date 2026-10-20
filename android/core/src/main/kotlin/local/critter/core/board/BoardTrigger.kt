package local.critter.core.board

import kotlin.math.abs

/**
 * When the landscape board opens and closes by itself (spec §8.6): it opens once the phone has been charging,
 * lying in landscape and still for [holdMs] with the screen on; it closes [unplugExitMs] after the charger is
 * pulled, or once the phone has stood upright for [uprightExitMs] (lying flat does not close it). A board the
 * user closed stays closed until the next plug-in, and so does one the system would not show: an [Action.Open]
 * that is not followed by [onBoardShown] within [openTimeoutMs] (no overlay permission, or the OEM's "background
 * pop-up" switch is off) stops the asking until the charger is plugged in again, and is reported once as
 * [Action.Blocked].
 *
 * "Shown" means the board exists, from its creation to its destruction: a board whose screen was switched off is
 * still shown, so it is neither opened again nor left behind when the charger is pulled.
 *
 * Pure and single-threaded: the caller passes a monotonic clock and calls [onTick] at [nextDeadline].
 */
class BoardTrigger(
    private val holdMs: Long = 3_000,
    private val unplugExitMs: Long = 10_000,
    private val uprightExitMs: Long = 3_000,
    private val openTimeoutMs: Long = 2_000,
) {
    sealed interface Action {
        data object Open : Action
        data object Close : Action

        /** The last [Open] never came up, or could not be started: the system kept the board from opening. */
        data object Blocked : Action
        data object None : Action
    }

    /** How the phone is held, from gravity. */
    enum class Pose { Landscape, Upright, Other }

    private var charging = false
    private var screenOn = true
    private var shown = false
    private var suppressed = false

    /** Whether the board may open by itself (the setting); closing works either way. */
    var autoOpen = true

    /** Since when the phone has been charging, landscape and still (while the board is not up). */
    private var holdSince: Long? = null

    /** Since when the phone has been upright (while the board is up). */
    private var uprightSince: Long? = null

    /** When the charger was pulled (while the board is up). */
    private var unpluggedAt: Long? = null

    /** When the last [Action.Open] went out, until the board comes up. */
    private var openedAt: Long? = null

    /**
     * An [Action.Open] went out and has neither come up nor been given up on (the 2 s timeout, a failed start, the
     * charger pulled): a board that comes up now is the one it opened, not one the user opened by hand.
     */
    val awaitingOpen: Boolean get() = openedAt != null

    /**
     * The gravity sensor is needed only while charging with the screen on (no readings arrive with it off), and
     * only to open a board or to close one that is up.
     */
    val sensorWanted: Boolean get() = charging && screenOn && (shown || (autoOpen && !suppressed))

    fun onPower(charging: Boolean, nowMs: Long): Action {
        if (charging == this.charging) return evaluate(nowMs)
        this.charging = charging
        if (charging) {
            // A new plug-in lifts the suppression a manual exit (or a refused opening) put on this charge.
            suppressed = false
            unpluggedAt = null
            uprightSince = null
        } else {
            holdSince = null
            openedAt = null
            if (shown) unpluggedAt = nowMs
        }
        return evaluate(nowMs)
    }

    /** The screen went on or off. Nothing opens while it is off, and the pose is unknown until it is back on. */
    fun onScreen(on: Boolean, nowMs: Long): Action {
        if (on == screenOn) return evaluate(nowMs)
        screenOn = on
        holdSince = null
        uprightSince = null
        return evaluate(nowMs)
    }

    fun onOrientation(pose: Pose, still: Boolean, nowMs: Long): Action {
        if (!charging || !screenOn) return evaluate(nowMs)
        if (shown) {
            if (pose == Pose.Upright) {
                if (uprightSince == null) uprightSince = nowMs
            } else {
                uprightSince = null
            }
        } else if (pose == Pose.Landscape && still && autoOpen && !suppressed) {
            if (holdSince == null) holdSince = nowMs
        } else {
            holdSince = null
        }
        return evaluate(nowMs)
    }

    fun onTick(nowMs: Long): Action = evaluate(nowMs)

    /** The user left the board: no automatic opening until the charger is plugged in again. */
    fun onManualExit(@Suppress("UNUSED_PARAMETER") nowMs: Long) {
        suppressed = true
        holdSince = null
        uprightSince = null
        unpluggedAt = null
    }

    /** The board could not be started at all: same as an opening the system never showed, so [Action.Blocked]. */
    fun onOpenFailed(): Action {
        suppressed = true
        openedAt = null
        holdSince = null
        return Action.Blocked
    }

    fun onBoardShown(shown: Boolean) {
        if (shown) openedAt = null
        if (shown == this.shown) return
        this.shown = shown
        holdSince = null
        uprightSince = null
        if (!shown) unpluggedAt = null
    }

    /** The next time [onTick] has something to decide, or null. */
    fun nextDeadline(): Long? = listOfNotNull(
        holdSince?.let { it + holdMs },
        uprightSince?.let { it + uprightExitMs },
        unpluggedAt?.let { it + unplugExitMs },
        openedAt?.let { it + openTimeoutMs },
    ).minOrNull()

    private fun evaluate(nowMs: Long): Action {
        val opened = openedAt
        if (opened != null && !shown && nowMs - opened >= openTimeoutMs) {
            // Asked, and nothing came up: the system blocks it. Retrying every few seconds would only burn power.
            openedAt = null
            suppressed = true
            holdSince = null
            return Action.Blocked
        }
        val hold = holdSince
        if (hold != null && !shown && charging && screenOn && autoOpen && !suppressed && nowMs - hold >= holdMs) {
            // Needs a fresh hold before it asks again.
            holdSince = null
            openedAt = nowMs
            return Action.Open
        }
        if (shown) {
            val upright = uprightSince
            val unplugged = unpluggedAt
            if ((upright != null && nowMs - upright >= uprightExitMs) ||
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
         * screen (|gz| < 6, so flat on a table is not landscape). Standing on a short edge, the usual way a phone
         * is held, gravity runs along the long axis (|gy| > 7): upright. Anything else (flat, propped far back,
         * in between) is neither.
         */
        fun poseOf(gx: Float, gy: Float, gz: Float): Pose = when {
            abs(gx) > 7f && abs(gz) < 6f -> Pose.Landscape
            abs(gy) > 7f -> Pose.Upright
            else -> Pose.Other
        }
    }
}
