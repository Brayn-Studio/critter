package local.critter.phone

import local.critter.phone.bridge.BoardPresence
import org.junit.jupiter.api.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BoardPresenceTest {
    @Test
    fun oneBoardComesAndGoes() {
        val boards = BoardPresence()
        assertFalse(boards.onScreen)
        boards.started()
        assertTrue(boards.onScreen)
        boards.stopped()
        assertFalse(boards.onScreen)
    }

    @Test
    fun aBoardReopenedRightAwayStaysOnScreen() {
        // Back, then the board again at once: the new board starts before the old one stops.
        val boards = BoardPresence()
        boards.started()
        boards.started()
        boards.stopped()
        assertTrue(boards.onScreen, "the new board is still up")
        boards.stopped()
        assertFalse(boards.onScreen)
    }

    @Test
    fun aStrayStopDoesNotHideTheNextBoard() {
        val boards = BoardPresence()
        boards.stopped()
        boards.started()
        assertTrue(boards.onScreen)
    }
}
