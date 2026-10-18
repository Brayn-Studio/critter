package local.critter.core.logic

import local.critter.core.pending
import local.critter.core.protocol.AnswerPayload
import local.critter.core.protocol.PendingKind
import local.critter.core.questions
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AnswerDraftTest {
    private fun permission() = AnswerDraft(pending("r", "s"))
    private fun plan() = AnswerDraft(pending("r", "s", PendingKind.plan))
    private fun question(vararg qs: Pair<String, Boolean>) =
        AnswerDraft(pending("r", "s", PendingKind.question, input = questions(*qs)))

    @Test fun answerDraftPermission() {
        val d = permission()
        assertNull(d.payload())
        d.allow()
        assertEquals(AnswerPayload(decision = "allow"), d.payload())
        d.deny(" ")
        assertEquals(AnswerPayload(decision = "deny", message = null), d.payload())
        d.deny("  Not now ")
        assertEquals(AnswerPayload(decision = "deny", message = "Not now"), d.payload())
    }

    @Test fun answerDraftRejectsTheWrongKindOfDecision() {
        val d = permission()
        d.approve()
        assertNull(d.payload())
        val p = plan()
        p.allow()
        assertNull(p.payload())
    }

    @Test fun answerDraftQuestionNeedsEveryQuestion() {
        val d = question("Which database?" to false, "Which cache?" to false)
        d.choose("Which database?", "PostgreSQL")
        assertNull(d.payload())
        d.choose("Which cache?", "Redis")
        assertEquals(
            AnswerPayload(answers = mapOf("Which database?" to "PostgreSQL", "Which cache?" to "Redis")),
            d.payload(),
        )
    }

    @Test fun answerDraftChoiceReplacesAndFreeTextOverrides() {
        val d = question("Q" to false)
        d.choose("Q", "A")
        d.choose("Q", "B")
        assertEquals(mapOf("Q" to "B"), d.payload()?.answers)
        d.freeText("Q", "  my own  ")
        assertEquals(mapOf("Q" to "my own"), d.payload()?.answers)
        d.freeText("Q", "   ")
        assertNull(d.payload())
    }

    @Test fun answerDraftIgnoresQuestionsItWasNotAsked() {
        val d = question("Q" to false)
        d.choose("Other question", "A")
        assertNull(d.payload())
    }

    @Test fun answerDraftMultiSelectJoinsLabels() {
        val d = question("Q" to true)
        d.toggle("Q", "A")
        d.toggle("Q", "B")
        d.toggle("Q", "C")
        d.toggle("Q", "B")
        assertEquals(mapOf("Q" to joinMultiSelect(listOf("A", "C"))), d.payload()?.answers)
        d.toggle("Q", "A")
        d.toggle("Q", "C")
        assertNull(d.payload())
    }

    @Test fun joinMultiSelectUsesCommaSpace() {
        assertEquals("A, B", joinMultiSelect(listOf("A", "B")))
    }

    @Test fun answerDraftRejectsAnswersOverTheLengthLimit() {
        val d = question("Q" to false)
        d.freeText("Q", "x".repeat(4001))
        assertNull(d.payload())
        d.freeText("Q", "x".repeat(4000))
        assertEquals(4000, d.payload()?.answers?.get("Q")?.length)
    }

    @Test fun answerDraftPlanReviseNeedsMessage() {
        val d = plan()
        assertNull(d.payload())
        d.approve()
        assertEquals(AnswerPayload(decision = "approve"), d.payload())
        d.revise("  ")
        assertNull(d.payload())
        d.revise(" Split step 2 ")
        assertEquals(AnswerPayload(decision = "revise", message = "Split step 2"), d.payload())
    }

    @Test fun answerDraftSubmitsOncePerRequest() {
        val d = permission()
        assertTrue(d.markSubmitted())
        assertFalse(d.markSubmitted())
    }
}
