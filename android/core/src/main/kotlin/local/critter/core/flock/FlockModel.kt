package local.critter.core.flock

import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PetState

/**
 * A user's explicit override of the automatic merge/expand decision (e.g. they manually
 * expanded a merged flock). Held by the app only as long as the session count it was made
 * against still matches -- once sessions are added or removed, the automatic rule resumes.
 */
data class FlockOverride(val merged: Boolean, val sessionCount: Int)

/** How many sessions share a given state, for the merged flock's summary badge. */
data class StateCount(val state: PetState, val count: Int)

/** What the flock window should currently render. */
sealed interface FlockPresentation {
    data object Empty : FlockPresentation

    data class Expanded(val sessions: List<BridgeSession>, val showCollapse: Boolean) : FlockPresentation

    data class Merged(val lead: BridgeSession, val counts: List<StateCount>, val total: Int) : FlockPresentation
}

/** Higher priority states win when multiple sessions must be summarized into one: waiting > error > done > running > idle. */
val PetState.priority: Int
    get() = when (this) {
        PetState.waiting -> 4
        PetState.error -> 3
        PetState.done -> 2
        PetState.running -> 1
        PetState.idle -> 0
        PetState.unknown -> -1
    }

/**
 * Decides whether to show every session's own Critter, or merge them into one representative
 * Critter with a summary badge -- automatically above `threshold`, or per the user's
 * `override` while it still applies. A session's sort key is its `startedAt` (the Mac's
 * `PetSession.sortKey`).
 */
object FlockModel {
    private val countOrder = listOf(PetState.waiting, PetState.error, PetState.done, PetState.running, PetState.idle)

    fun present(sessions: List<BridgeSession>, threshold: Int, override: FlockOverride?): FlockPresentation {
        if (sessions.isEmpty()) return FlockPresentation.Empty
        if (sessions.size == 1) return FlockPresentation.Expanded(sessions, showCollapse = false)

        val shouldMerge = if (override != null && override.sessionCount == sessions.size) {
            override.merged
        } else {
            sessions.size > threshold
        }

        if (!shouldMerge) return FlockPresentation.Expanded(sessions, showCollapse = sessions.size >= 2)
        return merged(sessions)
    }

    /**
     * The merged pile for `sessions` (non-empty): the most urgent session in front (the
     * earliest started among equals) and a count per state.
     */
    fun merged(sessions: List<BridgeSession>): FlockPresentation.Merged {
        val leadState = mostUrgent(sessions.map { it.state }) ?: PetState.idle
        val lead = sessions.filter { it.state == leadState }.minByOrNull { it.startedAt } ?: sessions[0]

        val counts = countOrder.mapNotNull { state ->
            val count = sessions.count { it.state == state }
            if (count > 0) StateCount(state, count) else null
        }

        return FlockPresentation.Merged(lead = lead, counts = counts, total = sessions.size)
    }

    /** The most urgent state among `states`, or null if `states` is empty. */
    fun mostUrgent(states: List<PetState>): PetState? = states.maxByOrNull { it.priority }
}
