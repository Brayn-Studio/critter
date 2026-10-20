package local.critter.phone.critter

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import local.critter.core.motion.ActorSnapshot
import local.critter.core.motion.GlyphDraw
import local.critter.core.skin.Tint
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Draws one Critter's [ActorSnapshot], following `CritterSpriteLayer` on the desktop: a shadow, the body
 * (clipped at the ground, so a sinking pose disappears into it), then props, particles, the head marker and
 * the badge, in that order and never clipped.
 *
 * Coordinates: the ground origin `(gx, gy)` is where the base box's column 0 meets the ground, in view pixels
 * with y down; cells are `u` pixels. The snapshot's y values grow upward, so they are subtracted.
 * Nothing here allocates: the paints and rectangles are reused, and the bitmaps come from the atlas.
 */
class CritterRenderer {
    private val bitmapPaint = Paint().apply {
        isFilterBitmap = false // nearest-neighbour: the pixel art stays crisp when scaled up
        isAntiAlias = false
        isDither = false
    }
    private val shadowPaint = Paint().apply {
        color = Color.BLACK
        alpha = (SHADOW_OPACITY * 255).roundToInt()
        isAntiAlias = false
    }
    private val rect = RectF()

    fun draw(canvas: Canvas, s: ActorSnapshot, atlas: SpriteAtlas, gx: Float, gy: Float, u: Float, seatRow: Int?) {
        if (s.hidden) return
        // The anchor plus the follow offset.
        val bx = gx + s.offsetX * u
        val by = gy - s.offsetY * u // the ground line of this Critter, y down

        // Shadow: just below the ground, centred under the body. A seated Critter casts none, like the still pile.
        val seated = seatRow != null && s.bodyX == 0 && s.bodyY == seatRow
        if (s.shadowWidth > 0 && !seated) {
            val width = s.shadowWidth.toFloat()
            rect.set(bx + (s.bodyX + 9 - width / 2) * u, by, bx + (s.bodyX + 9 + width / 2) * u, by + max(2f, u / 2))
            canvas.drawRect(rect, shadowPaint)
        }

        // Body, clipped at the ground; the clip travels with the key's dx.
        val pose = atlas.pose(s.pose, dim = s.tint == Tint.dim)
        if (pose != null) {
            canvas.save()
            canvas.clipRect(
                bx + (s.bodyX - CLIP_MARGIN_CELLS) * u,
                by - CLIP_HEIGHT_CELLS * u,
                bx + (s.bodyX + BASE_COLUMNS + CLIP_MARGIN_CELLS) * u,
                by,
            )
            val grid = pose.grid
            val bottom = by - (GROUND_ROW - grid.minY - grid.height + s.bodyY) * u
            rect.set(bx + (s.bodyX + grid.minX) * u, bottom - grid.height * u, bx + (s.bodyX + grid.minX + grid.width) * u, bottom)
            bitmapPaint.alpha = (s.alpha * 255).roundToInt().coerceIn(0, 255)
            canvas.drawBitmap(pose.bitmap, null, rect, bitmapPaint)
            canvas.restore()
        }

        // Glyphs, bottom to top: props, particles, head marker, badge.
        for (d in s.props) glyph(canvas, d, atlas, bx, by, u)
        for (d in s.particles) glyph(canvas, d, atlas, bx, by, u)
        s.accessory?.let { glyph(canvas, it, atlas, bx, by, u) }
        s.badge?.let { glyph(canvas, it, atlas, bx, by, u) }
    }

    private fun glyph(canvas: Canvas, d: GlyphDraw, atlas: SpriteAtlas, bx: Float, by: Float, u: Float) {
        val bitmap = atlas.glyph(d.glyph, d.color) ?: return
        val top = by - (GROUND_ROW - d.y) * u
        rect.set(bx + d.x * u, top, bx + (d.x + atlas.glyphWidth(d.glyph)) * u, top + atlas.glyphHeight(d.glyph) * u)
        bitmapPaint.alpha = (d.alpha * 255).roundToInt().coerceIn(0, 255)
        canvas.drawBitmap(bitmap, null, rect, bitmapPaint)
    }

    companion object {
        /** A Critter's base box is 18 cells wide (the skin format's), the one width every stage places it by. */
        const val BASE_COLUMNS = 18

        private const val GROUND_ROW = 10
        /** The body clip reaches this far above the ground... */
        private const val CLIP_HEIGHT_CELLS = 40
        /** ...and this far to either side of the 18-cell base box. */
        private const val CLIP_MARGIN_CELLS = 12
        private const val SHADOW_OPACITY = 0.28
    }
}
