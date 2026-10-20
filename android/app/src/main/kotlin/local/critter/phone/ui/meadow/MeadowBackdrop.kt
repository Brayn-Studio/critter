package local.critter.phone.ui.meadow

import androidx.compose.foundation.layout.Spacer
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import local.critter.phone.ui.look.DEFAULT_CLOUDS
import local.critter.phone.ui.look.SkyTime
import local.critter.phone.ui.look.meadowCells
import local.critter.phone.ui.look.skyTimeAt
import local.critter.phone.ui.rememberMinuteClock
import local.critter.phone.ui.theme.LocalDarkTheme
import java.time.Instant
import java.time.ZoneId
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * The sky and grass behind the pets ([meadowCells]), the ground [ground] from the top, [cell] (whole pixels)
 * a cell; a scene may place its own [clouds] and [moon] (fractions, as in [meadowCells]) to keep them clear of
 * what it draws on the sky. Painted once into a bitmap per size and sky, kept by the draw cache, and drawn whole:
 * no per-frame work.
 */
@Composable
fun MeadowBackdrop(
    time: SkyTime,
    ground: Dp,
    modifier: Modifier,
    cell: Dp = 3.dp,
    clouds: List<Pair<Float, Float>> = DEFAULT_CLOUDS,
    moon: Pair<Float, Float> = DEFAULT_MOON,
) {
    Spacer(
        modifier.drawWithCache {
            val image = meadowImage(
                size.width.roundToInt(), size.height.roundToInt(), ground.roundToPx(), max(1, cell.roundToPx()), time, clouds, moon,
            )
            onDrawBehind { if (image != null) drawImage(image) }
        },
    )
}

/** The moon over the home meadow (the mockups' `[0.58, 0.3]`). */
internal val DEFAULT_MOON = 0.58f to 0.3f

private fun meadowImage(
    width: Int,
    height: Int,
    ground: Int,
    cell: Int,
    time: SkyTime,
    clouds: List<Pair<Float, Float>>,
    moon: Pair<Float, Float>,
): ImageBitmap? {
    if (width <= 0 || height <= 0) return null
    val image = ImageBitmap(width, height)
    val canvas = Canvas(image)
    val paint = Paint().apply { isAntiAlias = false }
    for (c in meadowCells(width, height, ground, cell, time, clouds = clouds, moon = moon)) {
        paint.color = Color(c.color)
        canvas.drawRect(c.x.toFloat(), c.y.toFloat(), (c.x + c.w).toFloat(), (c.y + c.h).toFloat(), paint)
    }
    return image
}

/** The sky for now: from the hour on the clock (it changes on the hour), always night in the dark theme. */
@Composable
fun currentSkyTime(): SkyTime {
    val dark = LocalDarkTheme.current
    val clock = rememberMinuteClock()
    val hour by remember { derivedStateOf { Instant.ofEpochMilli(clock.value).atZone(ZoneId.systemDefault()).hour } }
    return skyTimeAt(hour, dark)
}
