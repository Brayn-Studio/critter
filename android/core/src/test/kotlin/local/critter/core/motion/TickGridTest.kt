package local.critter.core.motion

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class TickGridTest {
    @Test
    fun takeCountsWholeTicksAndKeepsThePhase() {
        val grid = TickGrid(tickMs = 60, start = 100.0)
        assertEquals(0, grid.take(now = 100.05))
        assertEquals(2, grid.take(now = 100.15))
        assertTrue(abs(grid.lastTick - 100.12) < 1e-9)
        // Taken ticks are gone: asking again at the same moment yields nothing.
        assertEquals(0, grid.take(now = 100.15))
        assertEquals(1, grid.take(now = 100.18))
    }

    @Test
    fun aWakeRightOnTheGridLineCountsItsTick() {
        val grid = TickGrid(tickMs = 60, start = 0.0)
        assertEquals(1, grid.take(now = 0.0599))
    }

    @Test
    fun aLongStallIsCappedAndResyncs() {
        val grid = TickGrid(tickMs = 60, start = 0.0)
        assertEquals(TickGrid.maxCatchUpTicks, grid.take(now = 3600.0))
        assertEquals(3600.0, grid.lastTick)
    }

    @Test
    fun dueIsClampedToOneThroughMaxSleepTicks() {
        val grid = TickGrid(tickMs = 60, start = 10.0)
        assertTrue(abs(grid.due(afterTicks = 5) - 10.3) < 1e-9)
        assertTrue(abs(grid.due(afterTicks = 0) - 10.06) < 1e-9)
        assertTrue(abs(grid.due(afterTicks = Int.MAX_VALUE) - (10 + 60)) < 1e-9)
    }

    /**
     * Regression (batch D review): an animation started after the clock slept through a quiet
     * spell must start at "now". Catching up first means the next wake steps it by one tick,
     * not by the whole spell.
     */
    @Test
    fun catchingUpBeforeAChangeKeepsTheNewAnimationFromSkippingAhead() {
        val grid = TickGrid(tickMs = 60, start = 0.0)
        // Quiet: the clock sleeps 40 ticks; a hide arrives 20.5 ticks in.
        val arrival = 20.5 * 0.06
        assertEquals(20, grid.take(now = arrival)) // catch up before starting the vanish
        val wake = grid.due(afterTicks = 1) // the vanish changes the picture next tick
        assertTrue(wake > arrival)
        assertEquals(1, grid.take(now = wake))

        // Without catching up the first wake would have stepped the new clip 21 ticks at once.
        val stale = TickGrid(tickMs = 60, start = 0.0)
        assertEquals(21, stale.take(now = stale.due(afterTicks = 1) + 20 * 0.06))
    }
}
