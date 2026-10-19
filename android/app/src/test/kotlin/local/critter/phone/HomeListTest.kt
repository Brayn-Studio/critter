package local.critter.phone

import local.critter.core.protocol.BridgePending
import local.critter.core.protocol.PendingKind
import local.critter.phone.ui.board.CardRequest
import local.critter.phone.ui.home.InlineAnswer
import local.critter.phone.ui.home.inlineAnswer
import local.critter.phone.ui.home.openingDue
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class HomeListTest {
    private fun card(kind: PendingKind, more: Int = 0) = CardRequest(
        request = BridgePending(requestId = "r1", sessionId = "a", kind = kind, createdAt = 1),
        what = "想 运行 ls", detail = null, more = more,
    )

    /** Offline, the buttons are there but grey: a tap sends nothing (review focus 3). */
    @Test
    fun inlineAnswerNeedsConnection() {
        assertEquals(InlineAnswer.AllowDeny, inlineAnswer(card(PendingKind.permission), online = true))
        assertEquals(InlineAnswer.AllowDenyDisabled, inlineAnswer(card(PendingKind.permission), online = false))
    }

    @Test
    fun questionsAndPlansOpenTheCard() {
        assertEquals(InlineAnswer.Open, inlineAnswer(card(PendingKind.question), online = true))
        assertEquals(InlineAnswer.Open, inlineAnswer(card(PendingKind.plan), online = true))
        // Two permission requests: the buttons would act on one the card does not show.
        assertEquals(InlineAnswer.Open, inlineAnswer(card(PendingKind.permission, more = 1), online = true))
        assertEquals(InlineAnswer.Open, inlineAnswer(card(PendingKind.question), online = false))
        assertEquals(InlineAnswer.None, inlineAnswer(null, online = true))
        assertEquals(InlineAnswer.None, inlineAnswer(null, online = false))
    }

    @Test
    fun openingOncePerDay() {
        assertTrue(openingDue(null, 100))
        assertFalse(openingDue(100, 100))
        assertTrue(openingDue(99, 100))
    }
}
