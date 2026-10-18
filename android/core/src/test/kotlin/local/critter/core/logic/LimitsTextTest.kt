package local.critter.core.logic

import local.critter.core.protocol.RateWindow
import java.time.ZoneId
import java.time.ZonedDateTime
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class LimitsTextTest {
    private val zone = ZoneId.of("Asia/Shanghai")

    // Wednesday 2026-10-21 12:00 in Shanghai.
    private val now = ZonedDateTime.of(2026, 10, 21, 12, 0, 0, 0, zone).toInstant().toEpochMilli()

    private fun at(day: Int, hour: Int, minute: Int) =
        RateWindow(10.0, ZonedDateTime.of(2026, 10, day, hour, minute, 0, 0, zone).toInstant().toEpochMilli())

    @Test fun limitsTextPercent() {
        assertEquals("16%", LimitsText.percent(RateWindow(16.0, 0)))
        assertEquals("13%", LimitsText.percent(RateWindow(12.5, 0)))
        assertEquals("—", LimitsText.percent(null))
    }

    @Test fun limitsTextResetsVariants() {
        assertEquals("已重置", LimitsText.resets(at(21, 11, 59), now, zone))
        assertEquals("已重置", LimitsText.resets(at(21, 12, 0), now, zone))
        assertEquals("还剩 49 分钟", LimitsText.resets(at(21, 12, 49), now, zone))
        assertEquals("还剩 1 分钟", LimitsText.resets(RateWindow(1.0, now + 20_000), now, zone))
        assertEquals("21:40 重置", LimitsText.resets(at(21, 21, 40), now, zone))
        assertEquals("周四 09:00 重置", LimitsText.resets(at(22, 9, 0), now, zone))
        assertEquals("周一 00:05 重置", LimitsText.resets(at(26, 0, 5), now, zone))
        assertEquals("—", LimitsText.resets(null, now, zone))
    }

    @Test fun limitsTextStaleness() {
        val min = 60_000L
        assertNull(LimitsText.staleness(now - 30 * min, now))
        assertEquals("31 分钟前", LimitsText.staleness(now - 31 * min, now))
        assertEquals("119 分钟前", LimitsText.staleness(now - 119 * min, now))
        assertNull(LimitsText.staleness(now, now))
        assertEquals("2 小时前", LimitsText.staleness(now - 121 * min, now))
        assertEquals("5 小时前", LimitsText.staleness(now - 300 * min, now))
    }
}
