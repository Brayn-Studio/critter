package local.critter.phone.ui.look

import kotlin.math.abs
import kotlin.math.min

/**
 * How wide a label centred on slot [i] of a row may be (everything in dp: the slots' [centers], each label's
 * [natural] width, the row [widthDp] wide). Towards the nearest neighbour on each side with a label at the same
 * height ([taken]) it may use the space between them, less [gap], that the neighbour's label leaves: a neighbour
 * keeps half of it at most, less when its natural width needs less. With no neighbour it reaches [edge] from the
 * side. Labels stay centred and never overlap; a longer text is cut short. Used by the home meadow's name tags,
 * bubbles and pile counts.
 */
fun labelRoom(
    centers: List<Float>,
    natural: List<Float>,
    i: Int,
    widthDp: Float,
    gap: Float,
    edge: Float,
    taken: (Int) -> Boolean,
): Float {
    val c = centers[i]
    fun half(j: Int): Float {
        val space = abs(c - centers[j]) - gap
        return space - min(natural[j] / 2, space / 2)
    }
    val left = (i - 1 downTo 0).firstOrNull(taken)?.let(::half) ?: (c - edge)
    val right = (i + 1..centers.lastIndex).firstOrNull(taken)?.let(::half) ?: (widthDp - edge - c)
    return (2 * min(left, right)).coerceAtLeast(0f)
}
