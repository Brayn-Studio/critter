package local.critter.phone

import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PetState
import local.critter.core.protocol.SessionSource
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
}
