package local.critter.phone.critter

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import local.critter.core.motion.TickGrid

/**
 * The tick source: a main-thread timer on the skin's tick grid (`tickMs`, 60 ms for the bundled skins) that only
 * wakes on the tick where the picture can next change, like `MotionClock` on the desktop. `onTick(n)` advances `n` ticks (0 = just redraw),
 * draws, and returns how many ticks until something changes again; the timer then sleeps that long. Skipped
 * ticks are caught up on the next wake, so counters like the idle-to-sleep timer keep running. Stopped while
 * the view cannot be seen.
 *
 * Anything that changes what the actors do from outside a tick must [catchUp] first, so the ticks slept so far
 * are spent on the old animation, not on the new one.
 */
class CritterClock(tickMs: Long, private val onTick: (Int) -> Int) {
    private val handler = Handler(Looper.getMainLooper())
    private var grid = TickGrid(tickMs, start = now())
    private val wake = Runnable { fire() }

    var tickMs: Long = tickMs
        private set

    /** Runs on another skin's tick from now on; the ticks slept so far are spent on the old one first. */
    fun retune(tickMs: Long) {
        if (tickMs == this.tickMs) return
        catchUp()
        this.tickMs = tickMs
        grid = TickGrid(tickMs, start = now())
        if (isRunning) poke()
    }

    var isRunning = false
        private set

    fun start() {
        if (isRunning) return
        isRunning = true
        grid.restart(now())
        poke()
    }

    fun stop() {
        if (!isRunning) return
        isRunning = false
        handler.removeCallbacks(wake)
    }

    /** Steps the actors through the whole ticks slept so far (if any), right now. */
    fun catchUp() {
        if (!isRunning) return
        val ticks = grid.take(now())
        if (ticks > 0) schedule(onTick(ticks))
    }

    /** Redraws now (`onTick(0)`) and re-aims the timer, after something outside the clock changed the actors. */
    fun poke() {
        val next = onTick(0)
        if (isRunning) schedule(next)
    }

    private fun fire() {
        if (!isRunning) return
        val ticks = grid.take(now())
        schedule(if (ticks > 0) onTick(ticks) else 1)
    }

    private fun schedule(ticks: Int) {
        handler.removeCallbacks(wake)
        val delayMs = ((grid.due(ticks) - now()) * 1000).toLong().coerceAtLeast(0)
        handler.postDelayed(wake, delayMs)
    }

    private fun now(): Double = SystemClock.uptimeMillis() / 1000.0
}
