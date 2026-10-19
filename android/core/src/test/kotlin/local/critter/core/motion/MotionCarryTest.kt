package local.critter.core.motion

import local.critter.core.bundledSkin
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MotionCarryTest {
    private fun sprig(reduceMotion: Boolean = false) =
        MotionActor(skin = bundledSkin("sprig"), rng = MotionRNG(seed = 7), reduceMotion = reduceMotion)

    @Test
    fun carriedCritterWalksHomeAfterTheDrop() {
        val a = sprig()
        a.carry(10.0)
        assertEquals(10, a.snapshot().offsetX)
        a.walkHome()
        val offsets = mutableListOf<Int>()
        repeat(8) {
            a.step()
            val s = a.snapshot()
            offsets += s.offsetX
            if (s.offsetX != 0) assertTrue(s.pose in a.skin.interactions.walkLeft, s.pose)
        }
        assertEquals(listOf(8, 6, 5, 4, 3, 2, 1, 0), offsets)
        assertFalse(a.following)
    }

    @Test
    fun carryPersistsAcrossTicks() {
        val a = sprig()
        a.setMode(a.skin.interactions.held)
        a.lift = 3
        a.carry(10.0)
        repeat(30) {
            a.step()
            assertEquals(10, a.snapshot().offsetX, "tick $it")
        }
        assertFalse(a.following)
        a.setMode(null)
        a.walkHome()
        repeat(8) { a.step() }
        assertEquals(0, a.snapshot().offsetX)
    }

    @Test
    fun reducedMotionSnapsHome() {
        val a = sprig(reduceMotion = true)
        a.carry(10.0)
        a.walkHome()
        a.step()
        assertEquals(0, a.snapshot().offsetX)
        assertFalse(a.following)
    }
}
