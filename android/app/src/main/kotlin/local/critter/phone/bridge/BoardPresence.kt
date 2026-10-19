package local.critter.phone.bridge

/**
 * Whether a board is on screen, counted over the boards that have started and not yet stopped. Closing the board
 * and opening it again at once starts the new board before the old one stops; a single flag then ended up "off"
 * with a board on screen, and the floating pile came back over it.
 */
class BoardPresence {
    private var started = 0

    val onScreen: Boolean get() = started > 0

    fun started() {
        started++
    }

    /** A stop without a start (a board that closed itself before it counted) is ignored. */
    fun stopped() {
        if (started > 0) started--
    }
}
