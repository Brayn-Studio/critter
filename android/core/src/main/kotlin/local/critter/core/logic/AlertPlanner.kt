package local.critter.core.logic

import local.critter.core.protocol.BridgePending
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PetState
import local.critter.core.protocol.SnapshotBody

data class AlertPrefs(
    val vibrateOnWaiting: Boolean = true,
    val notifyDone: Boolean = false,
    val notifyError: Boolean = false,
)

/**
 * What to do in response to a new snapshot.
 *
 * @property vibrate buzz once, however many requests arrived
 * @property post notifications to show, one per new request
 * @property cancel request ids whose notifications should be withdrawn
 * @property sessionAlerts sessions that just finished or failed, with the state they entered
 * @property cancelSessionAlerts sessions whose done/error notification should go: they left that state, or ended
 * @property waitingNotices sessions waiting for something the phone cannot answer (`ask` is CLI-only, so a VS Code
 *   session never has a request): "<名字> 等你确认（请在电脑上处理）"
 * @property cancelWaitingNotices sessions whose waiting notice should go
 * @property reconcile the set of pending requests changed (or this is the first snapshot of the process): worth
 *   checking the notification shade for leftovers, such as a previous process's
 */
data class AlertPlan(
    val vibrate: Boolean,
    val post: List<BridgePending>,
    val cancel: List<String>,
    val sessionAlerts: List<Pair<BridgeSession, PetState>>,
    val cancelSessionAlerts: List<String> = emptyList(),
    val waitingNotices: List<BridgeSession> = emptyList(),
    val cancelWaitingNotices: List<String> = emptyList(),
    val reconcile: Boolean = true,
)

object AlertPlanner {
    /**
     * Compares two consecutive snapshots. The first snapshot after connecting ([previous] == null)
     * only posts notifications: it describes the past, so it never buzzes or reports a finished session.
     */
    fun plan(previous: SnapshotBody?, current: SnapshotBody, prefs: AlertPrefs): AlertPlan {
        if (previous == null) return AlertPlan(false, current.pending, emptyList(), emptyList())

        val before = previous.pending.mapTo(HashSet()) { it.requestId }
        val after = current.pending.mapTo(HashSet()) { it.requestId }
        val previousState = previous.sessions.associate { it.id to it.state }

        val vibrate = prefs.vibrateOnWaiting &&
            current.sessions.any { it.state == PetState.waiting && previousState[it.id] != PetState.waiting }

        val sessionAlerts = current.sessions.mapNotNull { s ->
            val was = previousState[s.id] ?: return@mapNotNull null
            if (was == s.state) return@mapNotNull null
            val wanted = when (s.state) {
                PetState.done -> prefs.notifyDone
                PetState.error -> prefs.notifyError
                else -> false
            }
            if (wanted) s to s.state else null
        }

        return AlertPlan(
            vibrate = vibrate,
            post = current.pending.filter { it.requestId !in before },
            cancel = previous.pending.map { it.requestId }.filter { it !in after },
            sessionAlerts = sessionAlerts,
        )
    }

    /** Sessions in a done/error state: the ones whose result notification may stay up. */
    fun finishedSessions(body: SnapshotBody): Set<String> =
        body.sessions.filter { it.state == PetState.done || it.state == PetState.error }.mapTo(HashSet()) { it.id }
}

/**
 * [AlertPlanner] across a whole process: one per app, fed every live snapshot, told when the connection drops.
 *
 * A reconnect makes the next snapshot "the first" again (no buzz for what happened offline), but what was already
 * alerted is remembered, so a notification the user dismissed is not posted again on every reconnect; requests
 * that were resolved while offline are withdrawn.
 *
 * A request gets its notification once, the first time a live snapshot lists it while nothing on screen shows it.
 * Listed while the floating pile shows it (`notify = false`: the pile, or the board in its place), it waits: posted
 * when the pile goes out of sight ([pileHidden]: screen off, locked, hidden) or by the next snapshot out of sight,
 * if the Mac still lists it then; never if it was answered meanwhile.
 *
 * Not thread-safe: one caller (the service's main thread).
 */
class AlertTracker {
    private var previous: SnapshotBody? = null
    private var lastPending: Set<String>? = null

    /** Request ids notified (or due to be: a notification the system did not show counts) and still listed. */
    private val alerted = HashSet<String>()

    /** Request ids still listed that only the pile (or the board) has shown so far: no notification yet. */
    private val shownOnPile = HashSet<String>()

    /** Sessions with a waiting notice up (or due, had the pile not been on screen). */
    private val noticed = HashSet<String>()

    /**
     * Sessions that had a request in their current waiting spell: answering it leaves the session "waiting" until
     * the tool finishes, and that is not a reason to tell the user to go to the computer.
     */
    private val hadRequest = HashSet<String>()

    /** Sessions whose done/error notification may be up. */
    private val resulted = HashSet<String>()

    /** The connection dropped; the next snapshot describes the past again. */
    fun disconnected() {
        previous = null
    }

    /** Unpaired: forget everything. */
    fun reset() {
        previous = null
        lastPending = null
        alerted.clear()
        shownOnPile.clear()
        noticed.clear()
        hadRequest.clear()
        resulted.clear()
    }

    /**
     * The plan for the live snapshot [current]. [notify]: nothing on screen shows the requests (the floating pile is
     * out of sight); false holds new requests back for [pileHidden] instead of posting them. The buzz never waits.
     */
    fun next(current: SnapshotBody, prefs: AlertPrefs, notify: Boolean = true): AlertPlan {
        val base = AlertPlanner.plan(previous, current, prefs)
        val pendingIds = current.pending.mapTo(LinkedHashSet()) { it.requestId }
        val sessionIds = current.sessions.mapTo(HashSet()) { it.id }

        // Requests: post the never-notified ones (new, or held back while the pile showed them) when nothing shows
        // them; withdraw every notified one that is gone, offline or not.
        val cancel = alerted.filter { it !in pendingIds }
        alerted.retainAll(pendingIds)
        shownOnPile.retainAll(pendingIds)
        val due = current.pending.filter { it.requestId !in alerted }
        val post = if (notify) due else emptyList()
        due.mapTo(if (notify) alerted else shownOnPile) { it.requestId }
        if (notify) shownOnPile.clear()

        // Waiting with nothing the phone can answer.
        val withRequest = current.pending.mapTo(HashSet()) { it.sessionId }
        hadRequest.retainAll(sessionIds)
        for (s in current.sessions) {
            if (s.id in withRequest) hadRequest.add(s.id) else if (s.state != PetState.waiting) hadRequest.remove(s.id)
        }
        val wanted = current.sessions.filter {
            it.state == PetState.waiting && it.id !in withRequest && it.id !in hadRequest
        }
        val wantedIds = wanted.mapTo(HashSet()) { it.id }
        val waitingNotices = wanted.filter { it.id !in noticed }
        val cancelWaiting = noticed.filter { it !in wantedIds }
        noticed.retainAll(wantedIds)
        noticed.addAll(wantedIds)

        // Done / error: withdrawn once the session leaves that state (looked at on the Mac, or busy again).
        val finished = AlertPlanner.finishedSessions(current)
        val cancelResults = resulted.filter { it !in finished }
        resulted.retainAll(finished)
        base.sessionAlerts.forEach { resulted.add(it.first.id) }

        val reconcile = lastPending != pendingIds
        lastPending = pendingIds
        previous = current
        return base.copy(
            post = post,
            cancel = cancel,
            cancelSessionAlerts = cancelResults,
            waitingNotices = waitingNotices,
            cancelWaitingNotices = cancelWaiting,
            reconcile = reconcile,
        )
    }

    /**
     * The floating pile (or the board in its place) went out of sight: the requests only it has shown get their
     * notification now, those [current] (the newest live snapshot) still lists. No buzz: they buzzed when they came.
     */
    fun pileHidden(current: SnapshotBody): AlertPlan {
        val post = current.pending.filter { it.requestId in shownOnPile }
        // The rest were answered meanwhile.
        shownOnPile.clear()
        post.mapTo(alerted) { it.requestId }
        return AlertPlan(vibrate = false, post = post, cancel = emptyList(), sessionAlerts = emptyList(), reconcile = false)
    }
}
