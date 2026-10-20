package local.critter.phone

import local.critter.phone.overlay.PileHiding
import local.critter.phone.overlay.requestsInSight
import org.junit.jupiter.api.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PileSightTest {
    private val nothing = PileHiding(boardUp = false, sinkingForBoard = false, fullscreen = false, emptyAndAutoHide = false)

    @Test
    fun aPileOnScreenShowsTheRequests() {
        assertTrue(nothing.shown)
        assertTrue(requestsInSight(pileOn = true, screenInUse = true, hiding = nothing))
        assertFalse(requestsInSight(pileOn = true, screenInUse = false, hiding = nothing), "screen off or locked")
    }

    /** The board stands in for the pile it hides: notifications keep waiting. */
    @Test
    fun theBoardShowsWhatThePileWould() {
        val board = nothing.copy(boardUp = true)
        assertFalse(board.shown)
        assertTrue(board.copy(sinkingForBoard = true).shown, "still sinking into the ground")
        assertTrue(requestsInSight(pileOn = true, screenInUse = true, hiding = board))
        // The board is what makes the screen full: that rule does not hide the pile from under it.
        assertTrue(requestsInSight(pileOn = true, screenInUse = true, hiding = board.copy(fullscreen = true)))
    }

    /** Plan 4 final review M4: with the pile switched off, the board holds no notification back. */
    @Test
    fun theBoardHoldsNothingBackForAPileThatIsOff() {
        assertFalse(requestsInSight(pileOn = false, screenInUse = true, hiding = nothing.copy(boardUp = true)))
    }

    @Test
    fun aPileHiddenForItsOwnReasonsShowsNothing() {
        val fullscreen = nothing.copy(fullscreen = true)
        assertFalse(fullscreen.shown)
        assertFalse(requestsInSight(pileOn = true, screenInUse = true, hiding = fullscreen))
        val empty = nothing.copy(emptyAndAutoHide = true)
        assertFalse(empty.shown)
        assertFalse(requestsInSight(pileOn = true, screenInUse = true, hiding = empty.copy(boardUp = true)))
    }
}
