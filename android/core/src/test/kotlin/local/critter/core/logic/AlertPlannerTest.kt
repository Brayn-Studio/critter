package local.critter.core.logic

import local.critter.core.body
import local.critter.core.pending
import local.critter.core.protocol.PetState
import local.critter.core.session
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AlertPlannerTest {
    private val prefs = AlertPrefs()

    @Test fun alertPlannerFirstSnapshotPostsWithoutVibrating() {
        val current = body(listOf(session("a", PetState.waiting)), listOf(pending("r1", "a")))
        val plan = AlertPlanner.plan(null, current, prefs)
        assertFalse(plan.vibrate)
        assertEquals(listOf("r1"), plan.post.map { it.requestId })
        assertTrue(plan.cancel.isEmpty())
        assertTrue(plan.sessionAlerts.isEmpty())
    }

    @Test fun alertPlannerVibratesOncePerSnapshot() {
        val previous = body(listOf(session("a"), session("b")))
        val current = body(
            listOf(session("a", PetState.waiting), session("b", PetState.waiting)),
            listOf(pending("r1", "a"), pending("r2", "b")),
        )
        val plan = AlertPlanner.plan(previous, current, prefs)
        assertTrue(plan.vibrate)
        assertEquals(listOf("r1", "r2"), plan.post.map { it.requestId })
    }

    @Test fun alertPlannerStaysQuietForAlreadyWaitingSessions() {
        val waiting = body(listOf(session("a", PetState.waiting)), listOf(pending("r1", "a")))
        val plan = AlertPlanner.plan(waiting, waiting, prefs)
        assertFalse(plan.vibrate)
        assertTrue(plan.post.isEmpty())
        assertTrue(plan.cancel.isEmpty())
    }

    @Test fun alertPlannerHonoursTheVibratePreference() {
        val previous = body(listOf(session("a")))
        val current = body(listOf(session("a", PetState.waiting)), listOf(pending("r1", "a")))
        val plan = AlertPlanner.plan(previous, current, AlertPrefs(vibrateOnWaiting = false))
        assertFalse(plan.vibrate)
        assertEquals(1, plan.post.size)
    }

    @Test fun alertPlannerCancelsResolved() {
        val previous = body(listOf(session("a", PetState.waiting)), listOf(pending("r1", "a"), pending("r2", "a")))
        val current = body(listOf(session("a", PetState.waiting)), listOf(pending("r2", "a")))
        val plan = AlertPlanner.plan(previous, current, prefs)
        assertEquals(listOf("r1"), plan.cancel)
        assertTrue(plan.post.isEmpty())
    }

    @Test fun alertPlannerDoneOnlyWhenEnabled() {
        val previous = body(listOf(session("a", PetState.running), session("b", PetState.running)))
        val current = body(listOf(session("a", PetState.done), session("b", PetState.error)))

        assertTrue(AlertPlanner.plan(previous, current, AlertPrefs()).sessionAlerts.isEmpty())

        val doneOnly = AlertPlanner.plan(previous, current, AlertPrefs(notifyDone = true)).sessionAlerts
        assertEquals(listOf("a" to PetState.done), doneOnly.map { it.first.id to it.second })

        val errorOnly = AlertPlanner.plan(previous, current, AlertPrefs(notifyError = true)).sessionAlerts
        assertEquals(listOf("b" to PetState.error), errorOnly.map { it.first.id to it.second })

        val both = AlertPlanner.plan(previous, current, AlertPrefs(notifyDone = true, notifyError = true)).sessionAlerts
        assertEquals(2, both.size)
    }

    @Test fun alertPlannerDoesNotRepeatAnUnchangedDoneState() {
        val done = body(listOf(session("a", PetState.done)))
        val plan = AlertPlanner.plan(done, done, AlertPrefs(notifyDone = true))
        assertTrue(plan.sessionAlerts.isEmpty())
    }
}
