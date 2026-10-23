package local.critter.core.motion

import local.critter.core.builtin
import local.critter.core.skin.ClipKey
import local.critter.core.skin.EffectSpec
import local.critter.core.skin.SkinJson
import local.critter.core.skin.Span
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class ParticleTest {
    @Test
    fun dustParticleMovesAndDies() {
        val p = ParticleSpawner.spawn(builtin().effects["dust"]!!, cycleIndex = 0, rng = MotionRNG(seed = 1))[0]
        p.step(dt = 0.06)
        assertEquals(0, p.draw().x) // 1 - 12*0.06 = 0.28
        assertTrue(p.isAlive)
        repeat(3) { p.step(dt = 0.06) }
        assertFalse(p.isAlive) // life 4
    }

    @Test
    fun confettiHasSixteenCyclingColors() {
        val json = """{"particles": [{"count": 16, "glyph": "dot", "colors": ["#B39DF3", "#34C759", "#FFD60A", "#64D2FF", "#FF7096", "#F2F2F7"], "x": [5, 12], "y": -1, "vx": [-18, 18], "vy": [-34, -16], "ay": 80, "life": [13, 19]}]}"""
        val effect = SkinJson.decodeFromString(EffectSpec.serializer(), json)
        val colors = effect.particles!![0].colors!!
        val ps = ParticleSpawner.spawn(effect, cycleIndex = 0, rng = MotionRNG(seed = 3))
        assertEquals(16, ps.size)
        assertEquals(6, colors.size)
        for ((i, p) in ps.withIndex()) {
            assertEquals(colors[i % 6], p.color)
            assertTrue(p.x in 5.0..12.0)
            assertEquals(-1.0, p.y)
            assertTrue(p.vx in -18.0..18.0)
            assertTrue(p.vy in -34.0..-16.0)
            assertEquals(80.0, p.ay)
            assertTrue(p.life in 13..19)
        }
        assertTrue(ps.map { it.x }.toSet().size > 1)
    }

    @Test
    fun cycleEffectsTakeTheGroupForTheirTurn() {
        val zzz = builtin().effects["zzz"]!!
        val rng = MotionRNG(seed = 1)
        assertEquals(listOf("z"), ParticleSpawner.spawn(zzz, cycleIndex = 0, rng = rng).map { it.glyph })
        assertEquals(listOf("Z"), ParticleSpawner.spawn(zzz, cycleIndex = 1, rng = rng).map { it.glyph })
        assertEquals(listOf("z"), ParticleSpawner.spawn(zzz, cycleIndex = 2, rng = rng).map { it.glyph })
    }

    @Test
    fun drawRules() {
        // pop: lifted one cell for the first two ticks only
        val pop = Particle(glyph = "bang", color = "#FF3B30", x = 16.0, y = -7.0, life = 10, pop = true)
        assertEquals(-8, pop.draw().y)
        pop.step(dt = 0.06)
        assertEquals(-8, pop.draw().y)
        pop.step(dt = 0.06)
        assertEquals(-7, pop.draw().y)

        // sway: x + round(sin(age * 0.5) * sway)
        val sway = Particle(glyph = "z", color = "#A3A9B4", x = 15.0, y = -2.0, sway = 1.0, life = 30)
        assertEquals(15, sway.draw().x) // sin 0 = 0
        sway.age = 3
        assertEquals(16, sway.draw().x) // sin 1.5 ≈ 1.0
        sway.age = 7
        assertEquals(15, sway.draw().x) // sin 3.5 ≈ -0.35
        sway.age = 9
        assertEquals(14, sway.draw().x) // sin 4.5 ≈ -0.98

        // fades to half alpha once past 65 % of its life
        val fade = Particle(glyph = "dot", color = "#B4BAC4", x = 0.0, y = 0.0, life = 10)
        fade.age = 6
        assertEquals(1.0, fade.draw().alpha)
        fade.age = 7
        assertEquals(0.5, fade.draw().alpha)

        // twinkle shrinks to "dot" past half its life, shifted one cell right and down
        val twinkle = ParticleSpawner.spawn(builtin().effects["twinkle"]!!, cycleIndex = 0, rng = MotionRNG(seed = 1))[0]
        twinkle.age = 3
        assertEquals(GlyphDraw(glyph = "spark", color = "#E9EDF2", x = 14, y = -9, alpha = 1.0), twinkle.draw())
        twinkle.age = 4
        assertEquals(GlyphDraw(glyph = "dot", color = "#E9EDF2", x = 15, y = -8, alpha = 0.5), twinkle.draw())
    }

    @Test
    fun jsRoundMatchesMathRound() {
        assertEquals(-2, jsRound(-2.5))
        assertEquals(28, jsRound(27.5))
        assertEquals(-17, jsRound(-17.5))
        assertEquals(1, jsRound(1.28))
        assertEquals(0, jsRound(-0.4))
    }

    @Test
    fun rngIsDeterministicPerSeed() {
        val a = MotionRNG(seed = 42)
        val b = MotionRNG(seed = 42)
        val c = MotionRNG(seed = 43)
        val sa = (0 until 10).map { a.unit() }
        val sb = (0 until 10).map { b.unit() }
        val sc = (0 until 10).map { c.unit() }
        assertEquals(sa, sb)
        assertNotEquals(sa, sc)
        assertTrue(sa.all { it >= 0 && it < 1 })
    }

    @Test
    fun rngIntegersAreInclusive() {
        val rng = MotionRNG(seed = 5)
        val drawn = (0 until 500).map { rng.integer(0..2) }.toSet()
        assertEquals(setOf(0, 1, 2), drawn)
        val lives = (0 until 500).map { rng.integer(Span(13.0, 19.0)) }.toSet()
        assertEquals((13..19).toSet(), lives)
        assertEquals(4.0, rng.value(Span(4.0)))
    }

    @Test
    fun particleKnowsWhenItsDrawingChanges() {
        // A still particle changes only when it fades (age 7 of 10) -- or, past that, when it dies.
        val still = Particle(glyph = "dot", color = "#B4BAC4", x = 0.0, y = 0.0, life = 10)
        assertEquals(7, still.ticksUntilDrawChanges(dt = 0.06))
        val faded = still.copy(age = 7)
        assertEquals(3, faded.ticksUntilDrawChanges(dt = 0.06))

        // A floating z: each predicted tick is the first one drawn differently, and stepping that
        // far always lands on a different drawing (or the end of its life).
        val z = Particle(glyph = "z", color = "#A3A9B4", x = 15.0, y = -2.0, vx = 3.0, vy = -5.0, sway = 1.0, life = 30)
        val waits = mutableListOf<Int>()
        while (z.isAlive) {
            val wait = z.ticksUntilDrawChanges(dt = 0.06)
            waits += wait
            val before = z.draw()
            for (step in 1..wait) {
                z.step(dt = 0.06)
                if (step < wait) assertEquals(before, z.draw())
            }
            assertTrue(!z.isAlive || z.draw() != before)
        }
        assertEquals(30, waits.sum())
        assertTrue(waits.any { it > 1 }) // it doesn't need the clock every tick
    }

    @Test
    fun actorSleepsBetweenParticleMoves() {
        val a = MotionActor(skin = builtin(), rng = MotionRNG(seed = 7))
        a.setLoop(listOf(ClipKey(pose = "base", ticks = 1000)), null)
        a.brainEnabled = false
        a.particles = mutableListOf(Particle(glyph = "dot", color = "#B4BAC4", x = 0.0, y = 0.0, life = 10))
        assertEquals(7, a.ticksUntilChange()) // its fade, not every tick
        repeat(7) { a.step() }
        assertEquals(0.5, a.snapshot().particles.firstOrNull()?.alpha)
        assertEquals(3, a.ticksUntilChange()) // then its end
    }
}
