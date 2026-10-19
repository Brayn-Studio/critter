package local.critter.phone.ui.look

import kotlin.math.floor
import kotlin.math.min

/**
 * The stepped outline every surface shares with the pet's body (design §4): two steps of [step] at each corner.
 * Vertices as `x0, y0, x1, y1, …`, clockwise in y-down coordinates, starting at the lower point of the top-left
 * corner: 20 points, or 12 with [topOnly] (square bottom corners, for sheets). [step] is clamped to a quarter of
 * the shorter side, so the four steps of two corners always fit.
 */
fun pixelOutline(width: Float, height: Float, step: Float, topOnly: Boolean = false): FloatArray {
    val s = min(step, floor(min(width, height) / 4))
    val w = width
    val h = height
    val top = floatArrayOf(
        0f, 2 * s, s, 2 * s, s, s, 2 * s, s, 2 * s, 0f,
        w - 2 * s, 0f, w - 2 * s, s, w - s, s, w - s, 2 * s, w, 2 * s,
    )
    if (topOnly) return top + floatArrayOf(w, h, 0f, h)
    return top + floatArrayOf(
        w, h - 2 * s, w - s, h - 2 * s, w - s, h - s, w - 2 * s, h - s, w - 2 * s, h,
        2 * s, h, 2 * s, h - s, s, h - s, s, h - 2 * s, 0f, h - 2 * s,
    )
}
