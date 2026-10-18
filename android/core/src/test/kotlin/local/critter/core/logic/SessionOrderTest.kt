package local.critter.core.logic

import local.critter.core.body
import local.critter.core.pending
import local.critter.core.protocol.PetState
import local.critter.core.session
import kotlin.test.Test
import kotlin.test.assertEquals

class SessionOrderTest {
    @Test fun sessionOrderPutsWaitingFirst() {
        val b = body(
            sessions = listOf(session("a"), session("b", PetState.waiting), session("c"), session("d", PetState.waiting)),
            pending = listOf(pending("r1", "d", createdAt = 10), pending("r2", "b", createdAt = 20), pending("r3", "b", createdAt = 5)),
        )
        // b's oldest request (5) is older than d's (10), so b leads; a and c keep their order.
        assertEquals(listOf("b", "d", "a", "c"), SessionOrder.forBoard(b).map { it.id })
    }

    @Test fun sessionOrderKeepsTheOrderWhenNothingIsPending() {
        val b = body(listOf(session("a"), session("b")))
        assertEquals(listOf("a", "b"), SessionOrder.forBoard(b).map { it.id })
    }
}
