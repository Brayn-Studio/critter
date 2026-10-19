package local.critter.phone.ui.detail

import kotlin.math.PI
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Where the "发一句" letter is at each of its [steps] (1..[steps]) on the way from [from] to [to] (design §7): on
 * the straight line between them, lifted by `sin(t·π)·`[rise] into an arc, and snapped to whole [cell]s so it
 * moves on the pixel grid. The last step is [to] (snapped).
 */
fun letterPath(
    from: Pair<Float, Float>,
    to: Pair<Float, Float>,
    steps: Int = 7,
    rise: Float = 60f,
    cell: Float = 3f,
): List<Pair<Float, Float>> = (1..steps).map { i ->
    val t = i.toFloat() / steps
    val x = from.first + (to.first - from.first) * t
    val y = from.second + (to.second - from.second) * t - sin(t * PI).toFloat() * rise
    snap(x, cell) to snap(y, cell)
}

private fun snap(v: Float, cell: Float): Float = (v / cell).roundToInt() * cell
