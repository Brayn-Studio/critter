package local.critter.phone.ui.look

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.drawable.Drawable
import kotlin.math.max
import kotlin.math.min

/**
 * The pixel material for View code (the floating pile): a [pixelOutline] face in [fill] with a [lipPx]-high
 * bottom band of [lipColor] and optional top-left [highlight] cells. Sizes are in whole pixels.
 */
class PixelDrawable(
    private val fill: Int,
    private val stepPx: Int,
    private val lipPx: Int,
    private val lipColor: Int,
    private val highlight: Int? = null,
    private val topOnly: Boolean = false,
) : Drawable() {
    private val paint = Paint().apply { isAntiAlias = false }
    private val path = Path()
    private var alpha = 255

    override fun onBoundsChange(bounds: Rect) {
        path.reset()
        if (bounds.isEmpty) return
        val p = pixelOutline(bounds.width().toFloat(), bounds.height().toFloat(), stepPx.toFloat(), topOnly)
        path.moveTo(p[0], p[1])
        for (i in 2 until p.size step 2) path.lineTo(p[i], p[i + 1])
        path.close()
        path.offset(bounds.left.toFloat(), bounds.top.toFloat())
    }

    override fun draw(canvas: Canvas) {
        val b = bounds
        if (b.isEmpty) return
        canvas.save()
        canvas.clipPath(path)
        canvas.drawRect(b, paintOf(fill))
        if (lipPx > 0) canvas.drawRect(b.left.toFloat(), (b.bottom - lipPx).toFloat(), b.right.toFloat(), b.bottom.toFloat(), paintOf(lipColor))
        val hi = highlight
        val s = min(stepPx, min(b.width(), b.height()) / 4)
        if (hi != null && s > 0) {
            val p = paintOf(hi)
            for (i in HIGHLIGHT_X.indices) {
                val x = (b.left + HIGHLIGHT_X[i] * s).toFloat()
                val y = (b.top + HIGHLIGHT_Y[i] * s).toFloat()
                canvas.drawRect(x, y, x + s, y + s, p)
            }
        }
        canvas.restore()
    }

    private fun paintOf(color: Int): Paint = paint.apply {
        this.color = color
        this.alpha = Color.alpha(color) * this@PixelDrawable.alpha / 255
    }

    override fun setAlpha(alpha: Int) {
        this.alpha = alpha
        invalidateSelf()
    }

    override fun getAlpha(): Int = alpha

    override fun setColorFilter(colorFilter: ColorFilter?) {
        paint.colorFilter = colorFilter
        invalidateSelf()
    }

    @Deprecated("Deprecated in Java")
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT

    private companion object {
        /** (2s, s), (3s, s), (s, 2s), in steps; arrays, so drawing allocates nothing. */
        val HIGHLIGHT_X = intArrayOf(2, 3, 1)
        val HIGHLIGHT_Y = intArrayOf(1, 1, 2)
    }
}

/** [name] as a bitmap, [cellPx] (at least 1) pixels a cell, in [color]; for View code and notifications. */
fun PixelIcons.bitmap(name: String, color: Int, cellPx: Int): Bitmap {
    val icon = requireNotNull(rows[name]) { "no pixel icon '$name'" }
    val c = max(1, cellPx)
    val bitmap = Bitmap.createBitmap(icon[0].length * c, icon.size * c, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val paint = Paint().apply {
        isAntiAlias = false
        this.color = color
    }
    for (r in runs(icon)) canvas.drawRect((r[0] * c).toFloat(), (r[1] * c).toFloat(), ((r[0] + r[2]) * c).toFloat(), ((r[1] + 1) * c).toFloat(), paint)
    return bitmap
}
