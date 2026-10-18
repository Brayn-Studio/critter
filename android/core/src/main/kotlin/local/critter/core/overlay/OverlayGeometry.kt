package local.critter.core.overlay

import kotlin.math.max
import kotlin.math.min

/** A screen rectangle in pixels; stands in for `android.graphics.Rect` so the geometry is plain, testable code. */
data class Rect(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    val width: Int get() = right - left
    val height: Int get() = bottom - top
}

data class Size(val width: Int, val height: Int)

enum class Edge { Left, Right }

/** Where the floating pile rests: on [edge], with its top at [y] (screen pixels). */
data class Placement(val edge: Edge, val y: Int)

/** Where the floating pile may be, and how big its expanded column is. */
object OverlayGeometry {
    /** The expanded column takes at most this much of the screen height; beyond that it scrolls. */
    const val MAX_HEIGHT_FRACTION = 0.7

    /**
     * Where a window of [w] x [h] dropped with its top-left at ([x], [y]) ends up: first clamped back onto the
     * [screen] (also after a rotation or a split screen made the old position invalid), then snapped to the
     * nearer of the left and right edges.
     */
    fun snap(x: Int, y: Int, w: Int, h: Int, screen: Rect): Placement {
        val centre = (x + w / 2).coerceIn(screen.left, screen.right)
        val edge = if (centre < screen.left + screen.width / 2) Edge.Left else Edge.Right
        return Placement(edge, clampY(y, h, screen))
    }

    /** [y] moved so a window [h] tall is inside the screen (as far as it fits; taller than the screen: at the top). */
    fun clampY(y: Int, h: Int, screen: Rect): Int = y.coerceIn(screen.top, max(screen.top, screen.bottom - h))

    /** The window's left, flush with [edge]. */
    fun xFor(edge: Edge, w: Int, screen: Rect): Int = if (edge == Edge.Left) screen.left else screen.right - w

    /**
     * The expanded column for [count] sessions of [itemHeight] each (plus one more row for the collapse handle):
     * at most 70% of the screen height, so more sessions than fit scroll; wide enough for a bubble.
     */
    fun expandedSize(count: Int, screen: Rect, itemHeight: Int, width: Int = (itemHeight * 3.4).toInt()): Size {
        val wanted = (max(0, count) + 1) * itemHeight
        val cap = (screen.height * MAX_HEIGHT_FRACTION).toInt()
        return Size(min(width, (screen.width * 0.75).toInt()), min(wanted, max(cap, itemHeight)))
    }
}
