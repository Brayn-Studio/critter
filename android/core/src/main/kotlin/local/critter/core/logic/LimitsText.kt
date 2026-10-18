package local.critter.core.logic

import local.critter.core.protocol.RateWindow
import java.time.DayOfWeek
import java.time.Instant
import java.time.ZoneId
import kotlin.math.roundToInt

object LimitsText {
    private const val MINUTE = 60_000L
    private const val HOUR = 60 * MINUTE

    private val weekdays = mapOf(
        DayOfWeek.MONDAY to "周一", DayOfWeek.TUESDAY to "周二", DayOfWeek.WEDNESDAY to "周三",
        DayOfWeek.THURSDAY to "周四", DayOfWeek.FRIDAY to "周五", DayOfWeek.SATURDAY to "周六",
        DayOfWeek.SUNDAY to "周日",
    )

    fun percent(w: RateWindow?): String = w?.let { "${it.usedPercentage.roundToInt()}%" } ?: "—"

    fun resets(w: RateWindow?, nowMs: Long, zone: ZoneId): String {
        if (w == null) return "—"
        val left = w.resetsAt - nowMs
        if (left <= 0) return "已重置"
        if (left < HOUR) return "还剩 ${(left / MINUTE).coerceAtLeast(1)} 分钟"
        val at = Instant.ofEpochMilli(w.resetsAt).atZone(zone)
        val time = "%02d:%02d".format(at.hour, at.minute)
        val today = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
        return if (at.toLocalDate() == today) "$time 重置" else "${weekdays.getValue(at.dayOfWeek)} $time 重置"
    }

    /** How old the numbers are, once that is worth mentioning (over 30 minutes); null while they are fresh. */
    fun staleness(updatedAtMs: Long, nowMs: Long): String? {
        val age = nowMs - updatedAtMs
        return when {
            age > 2 * HOUR -> "${age / HOUR} 小时前"
            age > 30 * MINUTE -> "${age / MINUTE} 分钟前"
            else -> null
        }
    }
}
