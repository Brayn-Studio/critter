package local.critter.phone

import local.critter.phone.ui.board.IDLE_DIM_AFTER_MS
import local.critter.phone.ui.board.boardBrightness
import local.critter.phone.ui.board.boardClockText
import local.critter.phone.ui.board.boardDateText
import local.critter.phone.ui.board.randomShift
import org.junit.jupiter.api.Test
import java.time.ZoneId
import java.time.ZonedDateTime
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

    @Test
    fun clockAndDateReadLikeTheMockup() {
        val zone = ZoneId.of("Asia/Shanghai")
        val sunday = ZonedDateTime.of(2025, 10, 19, 22, 12, 0, 0, zone).toInstant().toEpochMilli()
        assertEquals("22:12", boardClockText(sunday, zone))
        assertEquals("10 月 19 日 星期日", boardDateText(sunday, zone))
        val morning = ZonedDateTime.of(2026, 3, 2, 7, 5, 0, 0, zone).toInstant().toEpochMilli()
        assertEquals("07:05", boardClockText(morning, zone))
        assertEquals("3 月 2 日 星期一", boardDateText(morning, zone))
    }
}
