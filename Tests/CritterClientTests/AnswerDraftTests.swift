import CritterClient
import CritterKit
import Testing

/// `AnswerDraftTest.kt`.
struct AnswerDraftTests {
    private func permission() -> AnswerDraft { AnswerDraft(request: fixturePending("r", "s")) }
    private func plan() -> AnswerDraft { AnswerDraft(request: fixturePending("r", "s", kind: .plan)) }
    private func question(_ qs: (String, Bool)...) -> AnswerDraft {
        AnswerDraft(request: fixturePending("r", "s", kind: .question, input: questionsInput(qs)))
    }

    @Test func answerDraftPermission() {
        let d = permission()
        #expect(d.payload() == nil)
        d.allow()
        #expect(d.payload() == AnswerPayload(decision: "allow"))
        d.deny(message: " ")
        #expect(d.payload() == AnswerPayload(decision: "deny", message: nil))
        d.deny(message: "  Not now ")
        #expect(d.payload() == AnswerPayload(decision: "deny", message: "Not now"))
        d.deny(message: nil)
        #expect(d.payload() == AnswerPayload(decision: "deny", message: nil))
    }

    @Test func answerDraftRejectsTheWrongKindOfDecision() {
        let d = permission()
        d.approve()
        #expect(d.payload() == nil)
        let p = plan()
        p.allow()
        #expect(p.payload() == nil)
    }

    @Test func answerDraftQuestionNeedsEveryQuestion() {
        let d = question(("Which database?", false), ("Which cache?", false))
        d.choose(question: "Which database?", label: "PostgreSQL")
        #expect(d.payload() == nil)
        d.choose(question: "Which cache?", label: "Redis")
        #expect(d.payload() == AnswerPayload(answers: ["Which database?": "PostgreSQL", "Which cache?": "Redis"]))
    }

    @Test func answerDraftChoiceReplacesAndFreeTextOverrides() {
        let d = question(("Q", false))
        d.choose(question: "Q", label: "A")
        d.choose(question: "Q", label: "B")
        #expect(d.payload()?.answers == ["Q": "B"])
        d.freeText(question: "Q", text: "  my own  ")
        #expect(d.payload()?.answers == ["Q": "my own"])
        d.freeText(question: "Q", text: "   ")
        #expect(d.payload() == nil)
    }

    @Test func answerDraftIgnoresQuestionsItWasNotAsked() {
        let d = question(("Q", false))
        d.choose(question: "Other question", label: "A")
        #expect(d.payload() == nil)
        d.toggle(question: "Other question", label: "A")
        d.freeText(question: "Other question", text: "x")
        #expect(d.payload() == nil)
    }

    @Test func answerDraftMultiSelectJoinsLabels() {
        let d = question(("Q", true))
        d.toggle(question: "Q", label: "A")
        d.toggle(question: "Q", label: "B")
        d.toggle(question: "Q", label: "C")
        d.toggle(question: "Q", label: "B")
        #expect(d.payload()?.answers == ["Q": ["A", "C"].joined(separator: BridgeProtocol.multiSelectSeparator)])
        d.toggle(question: "Q", label: "A")
        d.toggle(question: "Q", label: "C")
        #expect(d.payload() == nil)
    }

    /// Picks are sent in the question's option order, not the order they were tapped in.
    @Test func answerDraftMultiSelectFollowsTheOptionOrder() {
        let input = JSONValue.object(["questions": .array([.object([
            "question": .string("Q"), "multiSelect": .bool(true),
            "options": .array(["A", "B", "C"].map { .object(["label": .string($0)]) }),
        ])])])
        let d = AnswerDraft(request: fixturePending("r", "s", kind: .question, input: input))
        d.toggle(question: "Q", label: "C")
        d.toggle(question: "Q", label: "A")
        #expect(d.payload()?.answers == ["Q": "A, C"])
        d.toggle(question: "Q", label: "B")
        #expect(d.payload()?.answers == ["Q": "A, B, C"])
    }

    /// A label the question does not list goes after the listed ones, in the order it was tapped.
    @Test func answerDraftMultiSelectPutsUnlistedLabelsLast() {
        let input = JSONValue.object(["questions": .array([.object([
            "question": .string("Q"), "multiSelect": .bool(true),
            "options": .array(["A", "B"].map { .object(["label": .string($0)]) }),
        ])])])
        let d = AnswerDraft(request: fixturePending("r", "s", kind: .question, input: input))
        for label in ["Z", "B", "Y", "A"] { d.toggle(question: "Q", label: label) }
        #expect(d.payload()?.answers == ["Q": "A, B, Z, Y"])
    }

    @Test func multiSelectSeparatorIsCommaSpace() {
        #expect(BridgeProtocol.multiSelectSeparator == ", ")
    }

    @Test func answerDraftRejectsAnswersOverTheLengthLimit() {
        let d = question(("Q", false))
        d.freeText(question: "Q", text: String(repeating: "x", count: 4001))
        #expect(d.payload() == nil)
        d.freeText(question: "Q", text: String(repeating: "x", count: 4000))
        #expect(d.payload()?.answers?["Q"]?.count == 4000)
    }

    /// A chosen label is not trimmed by the draft, but the Mac measures it trimmed: a label that is only
    /// blanks is no answer.
    @Test func answerDraftRejectsABlankChoice() {
        let d = question(("Q", false))
        d.choose(question: "Q", label: " \n ")
        #expect(d.payload() == nil)
    }

    @Test func answerDraftPlanReviseNeedsMessage() {
        let d = plan()
        #expect(d.payload() == nil)
        d.approve()
        #expect(d.payload() == AnswerPayload(decision: "approve"))
        d.revise(message: "  ")
        #expect(d.payload() == nil)
        d.revise(message: " Split step 2 ")
        #expect(d.payload() == AnswerPayload(decision: "revise", message: "Split step 2"))
    }

    @Test func answerDraftQuestionWithoutQuestionsHasNoPayload() {
        let d = AnswerDraft(request: fixturePending("r", "s", kind: .question, input: .null))
        #expect(d.payload() == nil)
    }

    @Test func answerDraftSubmitsOncePerRequest() {
        let d = permission()
        #expect(d.markSubmitted())
        #expect(!d.markSubmitted())
    }
}
