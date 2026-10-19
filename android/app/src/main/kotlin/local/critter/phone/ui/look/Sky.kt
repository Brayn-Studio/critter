package local.critter.phone.ui.look

import kotlin.math.floor
import kotlin.math.max
import kotlin.math.roundToLong

/** The meadow's four skies; the light theme follows the clock, the dark theme is always night (design §5). */
enum class SkyTime { Dawn, Day, Dusk, Night }

fun skyTimeAt(hour: Int, dark: Boolean): SkyTime = when {
    dark -> SkyTime.Night
    hour in 6..9 -> SkyTime.Dawn
    hour in 10..16 -> SkyTime.Day
    hour in 17..19 -> SkyTime.Dusk
    else -> SkyTime.Night
}

/** A sky's colors as ARGB: three bands, clouds, grass, and the text and name tags drawn over it. */
data class SkyColors(
    val top: Long,
    val middle: Long,
    val bottom: Long,
    val cloud: Long,
    val grass: Long,
    val grassHi: Long,
    val grassLo: Long,
    val onSky: Long,
    val tag: Long,
    val tagInk: Long,
)

private const val INK = 0xFF2A2140
private const val NIGHT_INK = 0xFFF3F0FC
private const val TAG_DAY = 0xE0FFFFFF // white 88%
private const val TAG_NIGHT = 0xD117142A // #17142A 82%

fun skyColors(time: SkyTime): SkyColors = when (time) {
    SkyTime.Dawn -> SkyColors(0xFFBFE3FF, 0xFFDDF0FF, 0xFFFFE7CC, 0xFFFFFFFF, 0xFF8ED07A, 0xFFB5E39C, 0xFF6DB65A, INK, TAG_DAY, INK)
    SkyTime.Day -> SkyColors(0xFF9FD6FF, 0xFFC4E8FF, 0xFFE8F6FF, 0xFFFFFFFF, 0xFF8ED07A, 0xFFB5E39C, 0xFF6DB65A, INK, TAG_DAY, INK)
    // White words on the dusk sky; the white tags keep ink.
    SkyTime.Dusk -> SkyColors(0xFF7A69DA, 0xFFE09BC4, 0xFFFFCF9E, 0xFFF6C9E0, 0xFF8ED07A, 0xFFB5E39C, 0xFF6DB65A, 0xFFFFFFFF, TAG_DAY, INK)
    SkyTime.Night -> SkyColors(0xFF1E1B3A, 0xFF2B2752, 0xFF3B3466, 0xFF4A4380, 0xFF2F5A33, 0xFF3E7342, 0xFF22452A, NIGHT_INK, TAG_NIGHT, NIGHT_INK)
}

/** One filled rectangle of the meadow picture, in pixels, ARGB. */
data class MeadowCell(val x: Int, val y: Int, val w: Int, val h: Int, val color: Long)

/** Where the clouds float, as fractions of the width and of the sky's height. */
val DEFAULT_CLOUDS: List<Pair<Float, Float>> = listOf(0.08f to 0.2f, 0.62f to 0.1f, 0.86f to 0.36f)

private val CLOUD = listOf("....####......", "..#########...", ".############.", "##############")
private val MOON = listOf("..####.", ".###...", "###....", "###....", "###....", ".###...", "..####.")
private const val STAR = 0xFFFFF3C4

/**
 * The meadow behind the pets, as rectangles to paint in order (the mockups' `paintMeadow`): three sky bands
 * split at 42% and 74% of [ground] with one dithered row each way at each edge; clouds by day, stars and the
 * moon at night; then grass from [ground] down with a light top row, tufts and dark specks. Everything is on
 * the [cell] grid; [seed] fixes the stars and specks.
 */
fun meadowCells(
    width: Int,
    height: Int,
    ground: Int,
    cell: Int,
    time: SkyTime,
    seed: Int = 7,
    clouds: List<Pair<Float, Float>> = DEFAULT_CLOUDS,
    moon: Pair<Float, Float> = 0.58f to 0.3f,
): List<MeadowCell> {
    val c = skyColors(time)
    val p = max(1, cell)
    val out = ArrayList<MeadowCell>()
    fun snap(v: Double): Int = floor(v / p + 0.5).toInt() * p
    fun rows(rows: List<String>, x: Int, y: Int, color: Long) {
        for (r in PixelIcons.runs(rows)) out += MeadowCell(x + r[0] * p, y + r[1] * p, r[2] * p, p, color)
    }
    fun dither(y: Int, upper: Long, lower: Long) {
        var x = 0
        var i = 0
        while (x < width) {
            if (i % 2 == 0) out += MeadowCell(x, y, p, p, upper)
            if (i % 4 == 1) out += MeadowCell(x, y - p, p, p, lower)
            x += p
            i++
        }
    }

    val b1 = snap(ground * 0.42)
    val b2 = snap(ground * 0.74)
    out += MeadowCell(0, 0, width, b1, c.top)
    out += MeadowCell(0, b1, width, b2 - b1, c.middle)
    out += MeadowCell(0, b2, width, ground - b2, c.bottom)
    if (ground > 40) {
        dither(b1, c.top, c.middle)
        dither(b2, c.middle, c.bottom)
    }
    val random = Lcg(seed)
    if (time == SkyTime.Night) {
        val stars = (width.toLong() * ground / 2600.0).roundToLong()
        for (i in 0 until stars) {
            val x = snap(random.next() * width)
            val y = snap(random.next() * ground * 0.7)
            out += MeadowCell(x, y, p, p, if (random.next() > 0.75) STAR else alpha(0xFFFFFFFF, 0.75))
        }
        if (ground > 60) rows(MOON, snap(width * moon.first.toDouble()), snap(ground * moon.second.toDouble()), alpha(STAR, 0.95))
    } else if (ground > 60) {
        for ((fx, fy) in clouds) rows(CLOUD, snap(width * fx.toDouble()), snap(ground * fy.toDouble()), alpha(c.cloud, 0.82))
    }

    out += MeadowCell(0, ground, width, height - ground, c.grass)
    out += MeadowCell(0, ground, width, p, c.grassHi)
    var x = 0
    var i = 0
    while (x < width) {
        if (i % 7 == 2) out += MeadowCell(x, ground - p, p, p, c.grassHi)
        if (i % 13 == 8) {
            out += MeadowCell(x, ground - 2 * p, p, p, c.grassHi)
            out += MeadowCell(x + p, ground - p, p, p, c.grassHi)
        }
        x += p
        i++
    }
    val specks = width.toDouble() * (height - ground) / 900
    var n = 0
    while (n < specks) {
        val sx = snap(random.next() * width)
        val sy = snap(ground + 2.0 * p + random.next() * max(0, height - ground - 3 * p))
        out += MeadowCell(sx, sy, p, p, c.grassLo)
        n++
    }
    return out
}

/** [argb] with its alpha replaced by [a] (0..1). */
private fun alpha(argb: Long, a: Double): Long = ((a * 255).roundToLong() shl 24) or (argb and 0xFFFFFF)

/** The mockups' `seeded`: a 32-bit linear congruential sequence in 0..1. */
private class Lcg(seed: Int) {
    private var s = seed.toLong() and 0xFFFFFFFFL

    fun next(): Double {
        s = (s * 1664525L + 1013904223L) and 0xFFFFFFFFL
        return s / 4294967296.0
    }
}
