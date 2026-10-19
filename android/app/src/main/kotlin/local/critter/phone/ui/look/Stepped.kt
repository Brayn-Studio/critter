package local.critter.phone.ui.look

import androidx.compose.animation.core.Easing
import kotlin.math.floor

/** [x] in 0..1 moved in [steps] jumps, like CSS `steps(n)`: the pet's 60 ms beat for small widgets (design §7). */
fun steppedFraction(x: Float, steps: Int): Float =
    if (x >= 1f) 1f else (floor(x * steps) / steps).coerceAtLeast(0f)

/** Three jumps: the switch knob's 180 ms = 3 ticks. */
val PixelSteps3: Easing = Easing { steppedFraction(it, 3) }
