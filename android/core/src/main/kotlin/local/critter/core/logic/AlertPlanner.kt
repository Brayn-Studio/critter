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
 */
data class AlertPlan(
    val vibrate: Boolean,
    val post: List<BridgePending>,
    val cancel: List<String>,
    val sessionAlerts: List<Pair<BridgeSession, PetState>>,
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
}
