package local.critter.core.motion

import local.critter.core.skin.EffectSpec
import kotlin.math.sin

/**
 * One live particle, in cells relative to the actor (x across the base box, y down, ground =
 * row 10); velocities in cells per second.
 */
data class Particle(
    var glyph: String,
    var color: String,
    var x: Double,
    var y: Double,
    var vx: Double = 0.0,
    var vy: Double = 0.0,
    var ay: Double = 0.0,
    var sway: Double = 0.0,
    var life: Int,
    var age: Int = 0,
    var pop: Boolean = false,
    var shrinkTo: String? = null,
) {
    fun step(dt: Double) {
        vy += ay * dt
        x += vx * dt
        y += vy * dt
        age += 1
    }

    val isAlive: Boolean get() = age < life

    /**
     * Ticks (of `dt` seconds) until it is drawn differently -- another cell, glyph or alpha --
     * or dies; at least 1. A slow particle (a floating z) keeps its cell for a few ticks.
     */
    fun ticksUntilDrawChanges(dt: Double): Int {
        val now = draw()
        val next = copy()
        var ticks = 0
        do {
            next.step(dt)
            ticks += 1
        } while (next.isAlive && next.draw() == now)
        return ticks
    }

    /** Where and how to draw it, relative to the particle frame (the caller adds the body offset). */
    fun draw(): GlyphDraw {
        val swayShift = jsRound(sin(age.toDouble() * 0.5) * sway).toDouble()
        var gx = jsRound(x + swayShift)
        var gy = jsRound(y) + (if (pop && age < 2) -1 else 0)
        var g = glyph
        val shrink = shrinkTo
        if (shrink != null && age.toDouble() > life.toDouble() / 2) {
            g = shrink
            gx += 1
            gy += 1
        }
        val alpha = if (age.toDouble() > 0.65 * life.toDouble()) 0.5 else 1.0
        return GlyphDraw(glyph = g, color = color, x = gx, y = gy, alpha = alpha)
    }
}

object ParticleSpawner {
    /**
     * The particles one trigger of `e` emits: all of `particles`, plus group
     * `cycleIndex % cycle.size` of `cycle`.
     */
    fun spawn(e: EffectSpec, cycleIndex: Int, rng: MotionRNG): List<Particle> {
        val group = (e.particles ?: emptyList()).toMutableList()
        val cycle = e.cycle
        if (cycle != null && cycle.isNotEmpty()) group += cycle[cycleIndex % cycle.size]
        val out = mutableListOf<Particle>()
        for (spec in group) {
            for (i in 0 until maxOf(1, spec.count ?: 1)) {
                val colors = spec.colors
                val color = if (colors != null && colors.isNotEmpty()) colors[i % colors.size] else spec.color ?: ""
                // The draws happen in this order: x, y, vx, vy, then life.
                val x = rng.value(spec.x)
                val y = rng.value(spec.y)
                val vx = spec.vx?.let { rng.value(it) } ?: 0.0
                val vy = spec.vy?.let { rng.value(it) } ?: 0.0
                out += Particle(
                    glyph = spec.glyph, color = color, x = x, y = y, vx = vx, vy = vy,
                    ay = spec.ay ?: 0.0, sway = spec.sway ?: 0.0, life = rng.integer(spec.life),
                    pop = spec.pop ?: false, shrinkTo = spec.shrinkTo,
                )
            }
        }
        return out
    }
}
