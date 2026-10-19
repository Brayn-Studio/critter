package local.critter.phone.ui.look

import kotlin.math.roundToInt

/** How many of [segments] cells a meter lights for [percent] (none for null), clamped to the meter. */
fun litSegments(percent: Double?, segments: Int): Int =
    if (percent == null) 0 else (percent / 100 * segments).roundToInt().coerceIn(0, segments)

/** A meter's color band: green while calm, amber when busy, red when nearly full. */
enum class MeterLevel { Calm, Busy, Hot }

fun meterLevel(percent: Double?): MeterLevel = when {
    percent == null || percent < 60 -> MeterLevel.Calm
    percent < 85 -> MeterLevel.Busy
    else -> MeterLevel.Hot
}
