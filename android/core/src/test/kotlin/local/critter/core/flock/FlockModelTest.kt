package local.critter.core.flock

import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PetState
import local.critter.core.protocol.SessionSource
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

/** `startedAt` is the sort key (the Mac's `PetSession.sortKey`). */
private fun s(id: String, state: PetState, sortKey: Long) = BridgeSession(
    id = id, name = id, source = SessionSource.terminal, state = state, cwd = "/x", skin = "clawd",
    eventTime = sortKey, startedAt = sortKey, tracked = true,
)

class FlockModelTest {
    @Test
    fun emptyIsEmpty() {
        assertEquals(FlockPresentation.Empty, FlockModel.present(emptyList(), threshold = 4, override = null))
    }

    @Test
    fun singleSessionNeverShowsCollapse() {
        val one = listOf(s("0", PetState.running, 0))
        assertEquals(FlockPresentation.Expanded(one, showCollapse = false), FlockModel.present(one, threshold = 4, override = null))
    }

    @Test
    fun autoMergeAboveThreshold() {
        val five = (0 until 5).map { s("$it", if (it == 3) PetState.waiting else PetState.running, it.toLong()) }
        val merged = FlockModel.present(five, threshold = 4, override = null)
        assertIs<FlockPresentation.Merged>(merged)
        assertEquals(5, merged.total)
        assertEquals("3", merged.lead.id)
        assertEquals(listOf(StateCount(PetState.waiting, 1), StateCount(PetState.running, 4)), merged.counts)
        assertEquals(
            FlockPresentation.Expanded(five.take(4), showCollapse = true),
            FlockModel.present(five.take(4), threshold = 4, override = null),
        )
    }

    @Test
    fun overrideHoldsUntilCountChanges() {
        val five = (0 until 5).map { s("$it", PetState.running, it.toLong()) }
        val override = FlockOverride(merged = false, sessionCount = 5)
        assertEquals(FlockPresentation.Expanded(five, showCollapse = true), FlockModel.present(five, threshold = 4, override = override))

        val six = five + s("5", PetState.running, 5)
        val merged = FlockModel.present(six, threshold = 4, override = override)
        // expected merged once the session count no longer matches the override
        assertIs<FlockPresentation.Merged>(merged)
        assertEquals(6, merged.total)
    }

    @Test
    fun mergedLeadIsEarliestAmongMostUrgentState() {
        // Two waiting sessions, "later" one should still lose to the earlier-sorted one even
        // though both share the most urgent state.
        val sessions = listOf(
            s("x", PetState.running, 0),
            s("y", PetState.waiting, 5),
            s("z", PetState.waiting, 2),
            s("w", PetState.running, 1),
            s("v", PetState.running, 3),
        )
        val merged = FlockModel.present(sessions, threshold = 4, override = null)
        assertIs<FlockPresentation.Merged>(merged)
        assertEquals(5, merged.total)
        assertEquals("z", merged.lead.id)
    }

    @Test
    fun countsOmitZeroAndOrderByPriority() {
        val sessions = listOf(
            s("0", PetState.done, 0),
            s("1", PetState.idle, 1),
            s("2", PetState.error, 2),
            s("3", PetState.idle, 3),
            s("4", PetState.done, 4),
        )
        val merged = FlockModel.present(sessions, threshold = 4, override = null)
        assertIs<FlockPresentation.Merged>(merged)
        assertEquals(5, merged.total)
        assertEquals(
            listOf(StateCount(PetState.error, 1), StateCount(PetState.done, 2), StateCount(PetState.idle, 2)),
            merged.counts,
        )
    }
}
