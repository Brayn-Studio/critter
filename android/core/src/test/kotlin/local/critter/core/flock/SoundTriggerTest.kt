package local.critter.core.flock

import local.critter.core.protocol.PetState
import kotlin.test.Test
import kotlin.test.assertEquals

/** The three tests of `SoundTrigger` in Tests/CritterCoreTests/FlockModelTests.swift. */
class SoundTriggerTest {
    @Test
    fun soundTriggers() {
        assertEquals(emptyList(), SoundTrigger.enteredAlertStates(null, mapOf("a" to PetState.waiting)))
        assertEquals(
            listOf(PetState.waiting, PetState.done),
            SoundTrigger.enteredAlertStates(mapOf("a" to PetState.running), mapOf("a" to PetState.waiting, "b" to PetState.done)),
        )
        assertEquals(
            emptyList(),
            SoundTrigger.enteredAlertStates(mapOf("a" to PetState.waiting), mapOf("a" to PetState.waiting)),
        )
    }

    @Test
    fun soundTriggersIgnoreNonAlertStates() {
        assertEquals(
            emptyList(),
            SoundTrigger.enteredAlertStates(mapOf("a" to PetState.idle), mapOf("a" to PetState.running)),
        )
    }

    @Test
    fun soundTriggersDedupeAndOrderByPriority() {
        assertEquals(
            listOf(PetState.waiting, PetState.error, PetState.done),
            SoundTrigger.enteredAlertStates(
                mapOf("a" to PetState.running, "b" to PetState.running, "c" to PetState.running),
                mapOf("a" to PetState.done, "b" to PetState.error, "c" to PetState.waiting),
            ),
        )
    }
}
