package local.critter.phone

import local.critter.core.protocol.ResultReason
import local.critter.core.protocol.ServerMessage
import local.critter.phone.bridge.InFlight
import local.critter.phone.ui.answer.AnswerOutcome
import local.critter.phone.ui.answer.answerOutcome
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class InFlightTest {
    @Test
    fun aSecondAnswerWhileTheFirstIsOutIsNotSent() {
        val answering = InFlight()
        assertTrue(answering.start("r1"))
        assertFalse(answering.start("r1"), "the notification button and the card tapped together")
        assertTrue(answering.start("r2"), "another request is not held up")
    }

    @Test
    fun onceTheFirstIsBackItMayBeSentAgain() {
        val answering = InFlight()
        answering.start("r1")
        answering.finish("r1")
        assertTrue(answering.start("r1"), "a retry after a failure")
        answering.finish("never-started")
        assertTrue(answering.start("never-started"))
    }

    /** It was this phone, and the first may still fail: the card stays open and says so, it does not claim the Mac. */
    @Test
    fun theRefusalSaysSendingNotHandledElsewhere() {
        val refusal = InFlight.alreadySending()
        assertFalse(refusal.ok)
        assertEquals(ResultReason.unknown, refusal.reason)
        assertTrue(InFlight.isAlreadySending(refusal))
        assertFalse(InFlight.isAlreadySending(ServerMessage.Result(null, false, ResultReason.unknown, "超时")))
        assertEquals(AnswerOutcome.Failed("正在发送…"), answerOutcome(refusal))
    }
}
