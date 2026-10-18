package local.critter.core.motion

/**
 * The animation clock's bookkeeping on the tick grid, with the time passed in (seconds): how
 * many whole ticks have passed since the last processed one, and when a change some ticks
 * ahead is due. The clock sleeps until the next change, so before anything outside a tick
 * changes what the actors do it must `take` the ticks slept so far -- otherwise the next wake
 * would step the new animation through the whole quiet spell.
 */
class TickGrid(tickMs: Long, start: Double = 0.0) {
    val tick: Double = maxOf(1L, tickMs).toDouble() / 1000

    /** When the last processed tick happened. */
    var lastTick: Double = start
        private set

    /** Starts counting afresh from `now` (the clock was stopped meanwhile). */
    fun restart(now: Double) {
        lastTick = now
    }

    /**
     * The whole ticks that have passed by `now` (0 if none), consumed: the grid moves on by
     * that many, keeping its phase -- or, after a stall longer than `maxCatchUpTicks`, takes
     * that many and resyncs to `now`.
     */
    fun take(now: Double): Int {
        val n = ((now - lastTick + SLACK) / tick).toLong()
        if (n < 1) return 0
        if (n > maxCatchUpTicks) {
            lastTick = now
            return maxCatchUpTicks
        }
        lastTick += n.toDouble() * tick
        return n.toInt()
    }

    /** When a change `afterTicks` after the last processed tick is due (1…`maxSleepTicks` ticks). */
    fun due(afterTicks: Int): Double =
        lastTick + afterTicks.coerceIn(1, maxSleepTicks).toDouble() * tick

    companion object {
        /** Never sleep longer than this many ticks (the engine returns a huge sentinel when nothing changes on its own). */
        const val maxSleepTicks = 1000

        /** After a longer stall (system sleep) take this many ticks, then resync to now. */
        const val maxCatchUpTicks = 1000

        /** A wake right on a grid line may come a hair early in floating point. */
        private const val SLACK = 0.002
    }
}
