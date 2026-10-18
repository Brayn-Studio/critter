package local.critter.core.flock

import local.critter.core.protocol.PetState

/**
 * Decides which states deserve a sound this update: only `waiting`/`done`/`error` states a session has just
 * *entered*, never ones it was already in (so a sound doesn't replay on every unrelated snapshot) and never on
 * first load (there is no "entering" anything yet). Port of Swift's `SoundTrigger`.
 */
object SoundTrigger {
    private val alertStates = listOf(PetState.waiting, PetState.error, PetState.done)

    /** The entered alert states, most urgent first; the caller plays only the first. */
    fun enteredAlertStates(old: Map<String, PetState>?, new: Map<String, PetState>): List<PetState> {
        if (old == null) return emptyList()
        val entered = HashSet<PetState>()
        for ((id, state) in new) {
            if (state in alertStates && old[id] != state) entered += state
        }
        return entered.sortedByDescending { it.priority }
    }
}
