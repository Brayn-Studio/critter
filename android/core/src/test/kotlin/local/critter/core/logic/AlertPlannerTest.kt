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

    // --- AlertTracker: the planner across reconnects --------------------------------------------

    /** A reconnect is a fresh baseline for buzzing, but a dismissed notification is not posted again. */
    @Test fun trackerDoesNotRepostAcrossReconnects() {
        val t = AlertTracker()
        val a = body(listOf(session("a", PetState.waiting)), listOf(pending("r1", "a")))
        assertEquals(listOf("r1"), t.next(a, prefs).post.map { it.requestId })

        t.disconnected()
        val again = t.next(a, prefs)
        assertFalse(again.vibrate)
        assertTrue(again.post.isEmpty())
        assertTrue(again.cancel.isEmpty())

        t.disconnected()
        val more = t.next(body(listOf(session("a", PetState.waiting)), listOf(pending("r1", "a"), pending("r2", "a"))), prefs)
        assertEquals(listOf("r2"), more.post.map { it.requestId })
    }

    @Test fun trackerWithdrawsRequestsResolvedWhileOffline() {
        val t = AlertTracker()
        t.next(body(listOf(session("a", PetState.waiting)), listOf(pending("r1", "a"), pending("r2", "a"))), prefs)
        t.disconnected()
        val plan = t.next(body(listOf(session("a", PetState.waiting)), listOf(pending("r2", "a"))), prefs)
        assertEquals(listOf("r1"), plan.cancel)
        assertTrue(plan.post.isEmpty())
    }

    @Test fun trackerStillBuzzesForNewWaitingWithinAConnection() {
        val t = AlertTracker()
        t.next(body(listOf(session("a"))), prefs)
        val plan = t.next(body(listOf(session("a", PetState.waiting)), listOf(pending("r1", "a"))), prefs)
        assertTrue(plan.vibrate)
        assertEquals(listOf("r1"), plan.post.map { it.requestId })
    }

    /** The shade is only scanned for leftovers when the pending set changed, and on the first snapshot. */
    @Test fun trackerReconcilesOnlyWhenThePendingSetChanges() {
        val t = AlertTracker()
        assertTrue(t.next(body(listOf(session("a"))), prefs).reconcile)
        assertFalse(t.next(body(listOf(session("a", PetState.running))), prefs).reconcile)
        assertTrue(t.next(body(listOf(session("a", PetState.waiting)), listOf(pending("r1", "a"))), prefs).reconcile)
        assertFalse(t.next(body(listOf(session("a", PetState.waiting)), listOf(pending("r1", "a"))), prefs).reconcile)
        t.disconnected()
        assertFalse(t.next(body(listOf(session("a", PetState.waiting)), listOf(pending("r1", "a"))), prefs).reconcile)
        assertTrue(t.next(body(listOf(session("a"))), prefs).reconcile)
    }

    /** A waiting session with no request (a VS Code session: `ask` is CLI-only) gets "请在电脑上处理", once. */
    @Test fun waitingWithoutARequestGetsANotice() {
        val t = AlertTracker()
        t.next(body(listOf(session("a", PetState.running))), prefs)
        val plan = t.next(body(listOf(session("a", PetState.waiting))), prefs)
        assertTrue(plan.vibrate)
        assertEquals(listOf("a"), plan.waitingNotices.map { it.id })
        assertTrue(t.next(body(listOf(session("a", PetState.waiting))), prefs).waitingNotices.isEmpty())
        // Not again after a reconnect.
        t.disconnected()
        assertTrue(t.next(body(listOf(session("a", PetState.waiting))), prefs).waitingNotices.isEmpty())
        // Withdrawn once the session moves on.
        val moved = t.next(body(listOf(session("a", PetState.running))), prefs)
        assertEquals(listOf("a"), moved.cancelWaitingNotices)
        // A new waiting spell is noticed again.
        assertEquals(listOf("a"), t.next(body(listOf(session("a", PetState.waiting))), prefs).waitingNotices.map { it.id })
    }

    @Test fun waitingNoticeGivesWayToARequestAndDoesNotReturnAfterTheAnswer() {
        val t = AlertTracker()
        t.next(body(listOf(session("a", PetState.running))), prefs)
        assertEquals(listOf("a"), t.next(body(listOf(session("a", PetState.waiting))), prefs).waitingNotices.map { it.id })
        // The request shows up a snapshot later: the notice goes, the request is posted.
        val asked = t.next(body(listOf(session("a", PetState.waiting)), listOf(pending("r1", "a"))), prefs)
        assertEquals(listOf("a"), asked.cancelWaitingNotices)
        assertEquals(listOf("r1"), asked.post.map { it.requestId })
        // Answered on the phone; the session stays "waiting" until the tool finishes. No "go to the computer".
        val answered = t.next(body(listOf(session("a", PetState.waiting))), prefs)
        assertTrue(answered.waitingNotices.isEmpty())
        assertEquals(listOf("r1"), answered.cancel)
        t.next(body(listOf(session("a", PetState.running))), prefs)
        assertEquals(listOf("a"), t.next(body(listOf(session("a", PetState.waiting))), prefs).waitingNotices.map { it.id })
    }

    @Test fun waitingNoticeIsWithdrawnWhenTheSessionEnds() {
        val t = AlertTracker()
        t.next(body(listOf(session("a", PetState.waiting))), prefs)
        assertEquals(listOf("a"), t.next(body(emptyList()), prefs).cancelWaitingNotices)
    }

    /** Done/error notifications go once the session leaves that state (looked at on the Mac, or busy again). */
    @Test fun resultNotificationIsWithdrawnWhenTheSessionLeavesDone() {
        val t = AlertTracker()
        val on = AlertPrefs(notifyDone = true, notifyError = true)
        t.next(body(listOf(session("a", PetState.running), session("b", PetState.running))), on)
        val finished = t.next(body(listOf(session("a", PetState.done), session("b", PetState.error))), on)
        assertEquals(setOf("a", "b"), finished.sessionAlerts.map { it.first.id }.toSet())
        assertTrue(finished.cancelSessionAlerts.isEmpty())
        val seen = t.next(body(listOf(session("a", PetState.idle), session("b", PetState.error))), on)
        assertEquals(listOf("a"), seen.cancelSessionAlerts)
        assertEquals(listOf("b"), t.next(body(emptyList()), on).cancelSessionAlerts)
    }

    /** A session the phone has not seen before: only a state just entered is reported, not one it arrives in. */
    @Test fun newSessionAlreadyDoneDoesNotAlert() {
        val on = AlertPrefs(notifyDone = true, notifyError = true)
        val previous = body(listOf(session("a", PetState.running)))
        val current = body(listOf(session("a", PetState.running), session("b", PetState.done), session("c", PetState.error)))
        assertTrue(AlertPlanner.plan(previous, current, on).sessionAlerts.isEmpty())

        // A new session that arrives with a permission request is posted as usual, and buzzes.
        val asking = body(
            listOf(session("a", PetState.running), session("d", PetState.waiting)),
            listOf(pending("r1", "d")),
        )
        val plan = AlertPlanner.plan(previous, asking, on)
        assertEquals(listOf("r1"), plan.post.map { it.requestId })
        assertTrue(plan.vibrate)
    }

    // --- seen only on the floating pile (or on the board in its place) ----------------------------

    private val asking = body(listOf(session("a", PetState.waiting)), listOf(pending("r1", "a")))
    private val answered = body(listOf(session("a", PetState.running)))

    /** The pile showed it and the user let it be; then the screen went off: the lock screen gets it, once. */
    @Test fun requestSeenOnlyOnThePileIsPostedWhenThePileGoes() {
        val t = AlertTracker()
        t.next(body(listOf(session("a"))), prefs)
        val seen = t.next(asking, prefs, notify = false)
        assertTrue(seen.post.isEmpty())
        assertTrue(seen.vibrate, "the buzz does not wait")

        val gone = t.pileHidden(asking)
        assertEquals(listOf("r1"), gone.post.map { it.requestId })
        assertFalse(gone.vibrate)
        assertTrue(gone.cancel.isEmpty())
        assertTrue(t.pileHidden(asking).post.isEmpty(), "only once")
        assertTrue(t.next(asking, prefs).post.isEmpty(), "and not again with the next snapshot")
        // Withdrawn once it is answered, like any other.
        assertEquals(listOf("r1"), t.next(answered, prefs).cancel)
    }

    @Test fun answeredWhileVisibleIsNotPostedLater() {
        val t = AlertTracker()
        t.next(asking, prefs, notify = false)
        val done = t.next(answered, prefs, notify = false)
        assertTrue(done.cancel.isEmpty(), "it never had a notification")
        assertTrue(t.pileHidden(answered).post.isEmpty())
        assertTrue(t.next(answered, prefs).post.isEmpty())
    }

    /**
     * The board stood in for the pile while it was up (plan 4 final review M4): what it held back is posted once
     * nothing shows it any more, whether the pile's going is reported or the next snapshot finds it out of sight.
     */
    @Test fun heldBackWhileInSightIsPostedOnceOutOfSight() {
        val t = AlertTracker()
        t.next(asking, prefs, notify = false) // the board is up, the pile hidden behind it
        t.next(asking, prefs, notify = false) // more snapshots meanwhile
        val out = t.next(asking, prefs, notify = true) // board closed with the screen off: no pile in sight
        assertEquals(listOf("r1"), out.post.map { it.requestId })
        assertFalse(out.vibrate)
        assertTrue(t.pileHidden(asking).post.isEmpty(), "not twice")
    }

    /** A request that already had its notification keeps it while the pile comes and goes; nothing is posted twice. */
    @Test fun alreadyNotifiedIsNotHeldBackOrRepostedByThePile() {
        val t = AlertTracker()
        assertEquals(listOf("r1"), t.next(asking, prefs).post.map { it.requestId })
        assertTrue(t.next(asking, prefs, notify = false).post.isEmpty())
        assertTrue(t.pileHidden(asking).post.isEmpty())
        assertEquals(listOf("r1"), t.next(answered, prefs, notify = false).cancel, "withdrawn while the pile shows too")
    }

    @Test fun trackerResetForgetsEverything() {
        val t = AlertTracker()
        val a = body(listOf(session("a", PetState.waiting)), listOf(pending("r1", "a")))
        t.next(a, prefs)
        t.reset()
        assertEquals(listOf("r1"), t.next(a, prefs).post.map { it.requestId })
    }
}
