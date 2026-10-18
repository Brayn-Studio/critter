package local.critter.core.motion

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/** A point; stands in for Swift's `CGPoint` (lengths in pt on the Mac, in dp here). */
data class Pt(val x: Double, val y: Double)

enum class GazeZone { left, right, up, down, center }

/** Where a Critter looks for a pointer position — design §4.11. */
object MotionGaze {
    /**
     * `pointer` and `center` (anchor + (9u, 7u)) with y up; null when the pointer is too far
     * away to care.
     */
    fun zone(pointer: Pt, center: Pt, unit: Double): GazeZone? {
        val dx = pointer.x - center.x
        val below = center.y - pointer.y // the preview measures y downward
        if (hypot(dx, below) > 170) return null
        if (below < -max(28.0, abs(dx) * 1.1)) return GazeZone.up
        if (dx < -6 * unit) return GazeZone.left
        if (dx > 6 * unit) return GazeZone.right
        return if (below > 10) GazeZone.down else GazeZone.center
    }
}

/**
 * Recognises rubbing back and forth over a Critter: 3 direction reversals within a second,
 * counting only horizontal moves of 3 pt or more.
 */
class RubDetector {
    private var lastX: Double? = null
    private var direction = 0.0
    private var reversals = mutableListOf<Double>()
    private var lastMove: Double? = null

    /** Feeds a pointer position; returns whether this counts as rubbing now. */
    fun move(x: Double, at: Double): Boolean {
        val last = lastX
        if (last != null) {
            val dx = x - last
            if (abs(dx) >= 3) {
                val d = if (dx > 0) 1.0 else -1.0
                if (direction != 0.0 && d != direction) reversals += at
                direction = d
                lastX = x
                lastMove = at
            }
        } else {
            lastX = x
        }
        reversals.removeAll { at - it >= 1 }
        return reversals.size >= 3
    }

    /** True once 0.7 s passed since the last counted move. */
    fun shouldEnd(at: Double): Boolean {
        val last = lastMove ?: return false
        return at - last > 0.7
    }

    fun reset() {
        lastX = null
        direction = 0.0
        reversals = mutableListOf()
        lastMove = null
    }
}

/** Where the pointer counts as being on a Critter — design §4.11 (and the preview's `actorAt`). */
object MotionHover {
    /**
     * Whether `pointer` is over the Critter whose base box meets the ground at `anchor` (column
     * 0; y up), drawn `offset` cells away while following: columns 1…17 of the box, from 2 pt
     * below the ground to 11 cells above it. With `pile`, the whole merged pile instead: from 1
     * cell left of the front Critter to 27 cells right, up to 13 cells above the ground.
     */
    fun contains(
        pointer: Pt,
        anchor: Pt,
        unit: Double,
        offset: Pair<Int, Int> = 0 to 0,
        pile: Boolean = false,
    ): Boolean {
        val x = anchor.x + offset.first.toDouble() * unit
        val ground = anchor.y + offset.second.toDouble() * unit
        val left = if (pile) -1.0 else 1.0
        val right = if (pile) 27.0 else 17.0
        val top = if (pile) 13.0 else 11.0
        return pointer.x >= x + left * unit && pointer.x <= x + right * unit &&
            pointer.y >= ground - 2 && pointer.y <= ground + top * unit
    }
}

/** The held Critter's sideways swing while dragged — design §4.10. */
object MotionDrag {
    /**
     * Lag in cells for a pointer that just moved `pointerDx` points sideways: it trails the
     * move, a cell per 3 pt, at most 3 cells either way.
     */
    fun lag(pointerDx: Double): Int = min(max(jsRound(-pointerDx / 3), -3), 3)

    /** One tick of settling with the pointer at rest: a cell back toward 0. */
    fun settle(lag: Int): Int = lag - Integer.signum(lag)
}
