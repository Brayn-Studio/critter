package local.critter.phone

import local.critter.core.motion.GazeZone
import local.critter.core.overlay.Edge
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PetState
import local.critter.core.protocol.SessionSource
import local.critter.phone.overlay.fitCounts
import local.critter.phone.overlay.inwardGaze
import local.critter.phone.overlay.pileCounts
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals

class OverlayLookTest {
    private fun session(id: String, state: PetState) = BridgeSession(
        id = id, name = id, source = SessionSource.terminal, state = state, cwd = "/p/$id",
        skin = "clawd", eventTime = 0, startedAt = 0, tracked = true,
    )

    /** The pile's count tag reads like the desktop's markers: waiting, running, done, error, idle; no zeros. */
    @Test
    fun pileCountsInDesktopOrder() {
        val mixed = listOf(
            session("a", PetState.idle), session("b", PetState.running), session("c", PetState.done),
            session("d", PetState.waiting), session("e", PetState.running),
        )
        assertEquals(listOf("q" to 1, "sun" to 2, "check" to 1, "z" to 1), pileCounts(mixed))

        val running = List(4) { session("r$it", PetState.running) }
        assertEquals(listOf("sun" to 4), pileCounts(running))

        assertEquals(listOf("bang" to 1, "z" to 1), pileCounts(listOf(session("x", PetState.unknown), session("y", PetState.error))))
        assertEquals(emptyList(), pileCounts(emptyList()))
    }

    /** What a count tag shows at a given width: the least urgent states go first (idle, done, running, error). */
    @Test
    fun fitCountsDropsTheLeastUrgentFirst() {
        val all = listOf("q" to 1, "sun" to 2, "check" to 1, "bang" to 1, "z" to 3)
        val tenEach = { entries: List<Pair<String, Int>> -> 10f * entries.size }
        assertEquals(all, fitCounts(all, 50f, tenEach))
        assertEquals(listOf("q" to 1, "sun" to 2, "check" to 1, "bang" to 1), fitCounts(all, 49f, tenEach))
        assertEquals(listOf("q" to 1, "sun" to 2, "bang" to 1), fitCounts(all, 30f, tenEach))
        assertEquals(listOf("q" to 1, "bang" to 1), fitCounts(all, 20f, tenEach))
        assertEquals(listOf("q" to 1), fitCounts(all, 10f, tenEach))
        // Never empty: the most urgent state stays, even when nothing fits.
        assertEquals(listOf("q" to 1), fitCounts(all, 0f, tenEach))
        assertEquals(listOf("sun" to 4), fitCounts(listOf("sun" to 4, "z" to 1), 15f, tenEach))
        assertEquals(emptyList(), fitCounts(emptyList(), 0f, tenEach))
    }

    /** Design §8.4: on the right edge the calm Critters look left, into the screen; on the left edge, right. */
    @Test
    fun thePileLooksIntoTheScreen() {
        assertEquals(GazeZone.left, inwardGaze(Edge.Right))
        assertEquals(GazeZone.right, inwardGaze(Edge.Left))
    }
}
