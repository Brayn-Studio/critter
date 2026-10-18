package local.critter.core.motion

import local.critter.core.builtin
import local.critter.core.skin.ClipKey
import local.critter.core.skin.Tint
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

private fun makeActor(reduceMotion: Boolean = false) =
    MotionActor(skin = builtin(), rng = MotionRNG(seed = 7), reduceMotion = reduceMotion)

class MotionPlaybackTest {
    @Test
    fun onceResumesLoopAndCompletesTrue() {
        val a = makeActor()
        a.setLoop("idle")
        var ok: Boolean? = null
        a.play("blink") { ok = it }
        assertEquals("blink", a.currentClipName)
        assertTrue(a.isPlayingOnce)
        a.step()
        assertNull(ok)
        a.step()
        assertEquals(true, ok)
        assertFalse(a.isPlayingOnce)
        assertEquals("idle", a.currentClipName)
        assertEquals(0, a.currentKeyIndex)
    }

    @Test
    fun replacingOnceCompletesFalse() {
        val a = makeActor()
        a.setLoop("idle")
        var first: Boolean? = null
        var second: Boolean? = null
        a.play("blink") { first = it }
        a.play("wink") { second = it }
        assertEquals(false, first)
        assertNull(second)
        assertEquals("wink", a.currentClipName)
        a.cancelOnce()
        assertEquals(false, second)
        assertEquals("idle", a.currentClipName)
        assertFalse(a.isPlayingOnce)
    }

    @Test
    fun modeTakesOverBaseUntilCleared() {
        val a = makeActor()
        a.setLoop("idle")
        a.setMode("held")
        assertEquals("held", a.modeName)
        assertEquals("held", a.currentClipName)
        a.setLoop("ask") // base changes underneath the mode
        assertEquals("held", a.currentClipName)
        a.setMode(null)
        assertNull(a.modeName)
        assertEquals("ask", a.currentClipName)
    }

    @Test
    fun onceOverModeResumesMode() {
        val a = makeActor()
        a.setLoop("idle")
        a.setMode("pet")
        var ok: Boolean? = null
        a.play("notice") { ok = it } // 2 ticks
        assertEquals("notice", a.currentClipName)
        a.step()
        a.step()
        assertEquals(true, ok)
        assertEquals("pet", a.currentClipName)
    }

    @Test
    fun effectFiresAtKeyStart() {
        val a = makeActor()
        a.setLoop("idle")
        a.play("jump") // key 0 fires "dust" (2 particles)
        assertEquals(2, a.particles.size)
        a.step() // key 1 fires "tilde" (2 more)
        assertEquals(4, a.particles.size)
    }

    @Test
    fun reduceMotionEmitsNoParticles() {
        val a = makeActor(reduceMotion = true)
        a.setLoop("idle")
        a.play("jump")
        assertTrue(a.particles.isEmpty())
        a.emit("dust")
        assertTrue(a.particles.isEmpty())
    }

    @Test
    fun unknownAndInternalEffectsAreIgnored() {
        val a = makeActor()
        a.emit("no_such_effect")
        a.emit("@seat")
        assertTrue(a.particles.isEmpty())
    }

    @Test
    fun completionMayStartAnotherClip() {
        val a = makeActor()
        a.setLoop("idle")
        a.play("blink") { a.play("wink") }
        a.step()
        a.step()
        assertEquals("wink", a.currentClipName)
        assertTrue(a.isPlayingOnce)
    }

    @Test
    fun bodyYFollowsKeyAndLift() {
        val a = makeActor()
        a.play(listOf(ClipKey(pose = "base", ticks = 3, dx = 1, dy = -2, effect = null)), null)
        assertNull(a.currentClipName)
        var s = a.snapshot()
        assertEquals("base", s.pose)
        assertEquals(1, s.bodyX)
        assertEquals(-2, s.bodyY)
        a.lift = 3
        a.lag = 2
        s = a.snapshot()
        assertEquals(1, s.bodyY)
        assertEquals(3, s.bodyX)
    }

    @Test
    fun shadowWidthByHeight() {
        val a = makeActor()
        fun width(dy: Int): Int {
            a.play(listOf(ClipKey(pose = "base", ticks = 3, dx = 0, dy = dy)), null)
            return a.snapshot().shadowWidth
        }
        assertEquals(10, width(2))
        assertEquals(6, width(4))
        assertEquals(6, width(5))
        assertEquals(2, width(6))
        assertEquals(0, width(0))
        assertEquals(0, width(-2))
        a.lift = 3
        assertEquals(6, width(0))
    }

    @Test
    fun particlesFollowBodyOffsets() {
        val a = makeActor()
        a.play(listOf(ClipKey(pose = "base", ticks = 5, dx = 2, dy = 0, effect = "dust")), null)
        a.lag = 1
        a.lift = 2
        val s = a.snapshot()
        assertEquals(2, s.particles.size)
        assertEquals(2 + 2 + 1, s.particles[0].x)
        assertEquals(9 - 2, s.particles[0].y)
        assertEquals("#B4BAC4", s.particles[0].color)
    }

    @Test
    fun snapshotCarriesLookAndHiddenDrawsNothing() {
        val a = makeActor()
        a.setLoop("idle")
        a.tint = Tint.dim
        a.alpha = 0.55
        a.z = 0
        a.emit("dust")
        assertEquals(2, a.snapshot().particles.size)
        a.hidden = true
        val s = a.snapshot()
        assertTrue(s.hidden)
        assertEquals(Tint.dim, s.tint)
        assertEquals(0.55, s.alpha)
        assertEquals(0, s.z)
        assertTrue(s.offsetX == 0 && s.offsetY == 0)
        assertTrue(s.particles.isEmpty())
        assertTrue(s.props.isEmpty())
        assertTrue(s.accessory == null && s.badge == null)
    }

    @Test
    fun ticksUntilChangeIsRemainingKeyTicks() {
        val a = makeActor()
        a.setLoop("idle")
        assertEquals(40, a.ticksUntilChange())
        repeat(10) { a.step() }
        assertEquals(30, a.ticksUntilChange())
        a.emit("dust")
        assertEquals(1, a.ticksUntilChange())
    }

    @Test
    fun clockCountsSteps() {
        val a = makeActor()
        assertEquals(0, a.clock)
        repeat(5) { a.step() }
        assertEquals(5, a.clock)
    }
}
