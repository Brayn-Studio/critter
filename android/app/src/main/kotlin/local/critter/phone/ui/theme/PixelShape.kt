package local.critter.phone.ui.theme

import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import local.critter.phone.ui.look.pixelOutline
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** [dp] as a whole number of pixels, at least 1: every cell, step and lip lands on the pixel grid. */
internal fun Density.wholePx(dp: Dp): Float = max(1, dp.toPx().roundToInt()).toFloat()

/** The [pixelOutline] polygon of a `width` × `height` box at (`dx`, `dy`). */
internal fun outlinePath(width: Float, height: Float, step: Float, topOnly: Boolean, dx: Float = 0f, dy: Float = 0f): Path {
    val p = pixelOutline(width, height, step, topOnly)
    return Path().apply {
        moveTo(p[0] + dx, p[1] + dy)
        for (i in 2 until p.size step 2) lineTo(p[i] + dx, p[i + 1] + dy)
        close()
    }
}

/** The pet body's stepped corners as a [Shape]: two steps of [step] (whole pixels) at each corner. */
data class PixelShape(val step: Dp, val topOnly: Boolean = false) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline =
        Outline.Generic(outlinePath(size.width, size.height, density.wholePx(step), topOnly))
}

/**
 * The pixel material (design §4): clipped to a [PixelShape] and filled with [color], with a [lip]-high band of
 * [lipColor] along the bottom (along the top when [recessed], for wells and tracks) and, on colored faces, the
 * three [highlight] cells at the top left. A [border] is drawn as two layers, the border color outside and the
 * face inset by [borderWidth] with steps 1 dp smaller, so the steps never break the line.
 */
fun Modifier.pixelSurface(
    color: Color,
    step: Dp = 4.dp,
    lip: Dp = 4.dp,
    lipColor: Color,
    highlight: Color? = null,
    recessed: Boolean = false,
    border: Color? = null,
    borderWidth: Dp = 3.dp,
    topOnly: Boolean = false,
): Modifier = clip(PixelShape(step, topOnly)).drawWithCache {
    val inset = if (border != null) wholePx(borderWidth) else 0f
    val faceW = size.width - 2 * inset
    val faceH = size.height - 2 * inset
    val faceStep = if (border != null) wholePx(step - 1.dp) else wholePx(step)
    val face = if (border != null) outlinePath(faceW, faceH, faceStep, topOnly, inset, inset) else null
    val lipPx = if (lip > 0.dp) wholePx(lip) else 0f
    val lipTop = if (recessed) inset else inset + faceH - lipPx
    val cell = min(faceStep, floor(min(faceW, faceH) / 4))
    onDrawBehind {
        if (border == null || face == null) {
            drawRect(color)
            if (lipPx > 0f) drawRect(lipColor, Offset(0f, lipTop), Size(faceW, lipPx))
        } else {
            drawRect(border)
            drawPath(face, color)
            if (lipPx > 0f) clipPath(face) { drawRect(lipColor, Offset(inset, lipTop), Size(faceW, lipPx)) }
        }
        if (highlight != null && cell > 0f) {
            val px = Size(cell, cell)
            drawRect(highlight, Offset(inset + 2 * cell, inset + cell), px)
            drawRect(highlight, Offset(inset + 3 * cell, inset + cell), px)
            drawRect(highlight, Offset(inset + cell, inset + 2 * cell), px)
        }
    }
}
