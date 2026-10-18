package local.critter.phone

import local.critter.phone.ui.board.IDLE_DIM_AFTER_MS
import local.critter.phone.ui.board.boardBrightness
import local.critter.phone.ui.board.randomShift
import org.junit.jupiter.api.Test
import kotlin.random.Random
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class BoardChromeTest {
    @Test
    fun dimsToSixtyPercentAfterFifteenIdleMinutes() {
        assertEquals(0.3f, boardBrightness(0.3f, 0))
        assertEquals(0.3f, boardBrightness(0.3f, IDLE_DIM_AFTER_MS - 1))
        assertEquals(0.18f, boardBrightness(0.3f, IDLE_DIM_AFTER_MS), 0.0001f)
    }

    @Test
    fun aTouchAfterTheLastTickMeansNotIdle() {
        // The clock lags the touch by up to a minute, so idle time can be negative.
        assertEquals(0.5f, boardBrightness(0.5f, -30_000))
    }

    @Test
    fun brightnessNeverReachesZero() {
        assertTrue(boardBrightness(0.1f, IDLE_DIM_AFTER_MS) > 0f)
    }

    @Test
    fun shiftStaysWithinFourDp() {
        val random = Random(42)
        repeat(500) {
            val (x, y) = randomShift(random)
            assertTrue(x in -4..4 && y in -4..4)
        }
    }
}
