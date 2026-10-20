package local.critter.phone

import local.critter.phone.ui.home.homeMoon
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class HomeMoonTest {
    private val width = 360f
    private val ground = 200f

    /** The mockup's "MacBook Pro" ends well short of the moon: the mockup's spot, 0.58 across and 0.3 down. */
    @Test fun aShortNameLeavesTheMockupsMoon() {
        assertEquals(0.58f to 0.3f, homeMoon(width, ground, nameRightDp = 148f, nameBottomDp = 66f))
    }

    /**
     * "文博的MacBook Pro" on the vivo (360 dp, measured 18..219 dp wide and down to 69.7 dp) reached into the moon at
     * 210 dp: it drops just under the name, in the same column.
     */
    @Test fun aLongNameSendsTheMoonUnderIt() {
        val (x, y) = homeMoon(width, ground, nameRightDp = 219f, nameBottomDp = 69.7f)
        assertEquals(0.58f, x)
        assertTrue(y * ground >= 69.7f + 4f - 0.001f, "the moon's top ${y * ground} must clear the name")
        // Still well above the Critters' heads (21 cells of 3 dp under the ground line) and their bubbles.
        assertTrue(y * ground + 21f < ground - 63f - 30f)
    }

    /** A long name whose line ends above the moon's top already (a short status bar) leaves the moon where it is. */
    @Test fun aLongNameAboveTheMoonLeavesIt() {
        assertEquals(0.58f to 0.3f, homeMoon(width, ground, nameRightDp = 240f, nameBottomDp = 50f))
    }

    /** A wider screen moves the moon right with it, so a name that fits short of it there leaves it alone. */
    @Test fun theMoonFollowsTheWidth() {
        assertEquals(0.58f to 0.3f, homeMoon(412f, ground, nameRightDp = 230f, nameBottomDp = 70f))
    }
}
