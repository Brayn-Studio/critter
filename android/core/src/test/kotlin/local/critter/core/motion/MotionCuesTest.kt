package local.critter.core.motion

import local.critter.core.bundledSkin
import kotlin.test.Test
import kotlin.test.assertEquals

class MotionCuesTest {
    @Test
    fun lookAtYouIsNoticeThenAHeldLookUp() {
        val clip = MotionCues.lookAtYou(bundledSkin("sprig"))
        assertEquals(listOf("attn", "base", "look_up", "shut", "look_up", "base"), clip.map { it.pose })
        assertEquals(29, clip.sumOf { it.ticks })
    }

    @Test
    fun hopLandsWithDust() {
        val skin = bundledSkin("sprig")
        val clip = MotionCues.hop(skin)
        assertEquals(5, clip.size)
        assertEquals(listOf(2, 4, 3, 1, 0), clip.map { it.dy })
        assertEquals(skin.interactions.landDust, clip.last().effect)
        assertEquals(6, clip.sumOf { it.ticks })
    }

    @Test
    fun cuesDoNotShareKeysWithTheSkin() {
        val skin = bundledSkin("sprig")
        MotionCues.lookAtYou(skin).first().ticks = 99
        assertEquals(2, skin.clips.getValue(skin.interactions.notice).first().ticks)
    }

    /** How long the hop lasts on screen: its ticks at the skin's tick (the floating shelf waits for it). */
    @Test
    fun hopMsIsItsTicksAtTheSkinsTick() {
        val skin = bundledSkin("sprig")
        assertEquals(6L * skin.tickMs, MotionCues.hopMs(skin))
    }
}
