package local.critter.core.motion

import local.critter.core.skin.Span
import kotlin.math.floor

/**
 * Rounds like JavaScript's `Math.round`, which the approved motion preview uses: halves go
 * toward +∞ (`-2.5 → -2`). `Math.round` on a `Double` happens to do the same, but the formula
 * is kept as in Swift (`Int(floor(v + 0.5))`) so the two stay obviously identical.
 */
fun jsRound(v: Double): Int = floor(v + 0.5).toInt()

/** A seedable random source (SplitMix64), so motion is reproducible in tests. */
class MotionRNG(seed: Long) {
    private var state: ULong = seed.toULong()

    private fun next(): ULong {
        state += 0x9E3779B97F4A7C15UL
        var z = state
        z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9UL
        z = (z xor (z shr 27)) * 0x94D049BB133111EBUL
        return z xor (z shr 31)
    }

    /** Uniform in [0, 1). */
    fun unit(): Double = (next() shr 11).toLong().toDouble() * TWO_POW_MINUS_53

    /** Uniform in `[s.min, s.max)`; a fixed span returns its value without drawing. */
    fun value(s: Span): Double = if (s.min == s.max) s.min else s.min + unit() * (s.max - s.min)

    /** Uniform integer in the closed range `[s.min, s.max]`. */
    fun integer(s: Span): Int {
        val lo = s.min.toInt()
        return integer(lo..maxOf(lo, s.max.toInt()))
    }

    fun integer(r: IntRange): Int = r.first + (unit() * (r.last - r.first + 1).toDouble()).toInt()

    companion object {
        private const val TWO_POW_MINUS_53 = 1.0 / 9007199254740992.0

        fun system(): MotionRNG = MotionRNG(java.util.concurrent.ThreadLocalRandom.current().nextLong())
    }
}
