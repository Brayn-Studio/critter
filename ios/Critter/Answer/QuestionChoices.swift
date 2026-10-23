import CritterClient
import Observation

/// What a question card shows as chosen: the labels picked per question, and the own answer being written. It is the
/// other half of the request's `AnswerDraft` and lives next to it in `AnswerDrafts`, so a card that is closed and
/// opened again shows exactly what the draft holds, and what is shown is what gets sent.
///
/// Every change goes through here, and each one is made to the draft in the same call. A new draft (after a failed
/// attempt) gets the choices put into it (`replay`).
@MainActor @Observable
final class QuestionChoices {
    /// The labels chosen per question, in the order tapped.
    private(set) var picked: [String: [String]] = [:]
    /// The questions whose own answer is being written.
    private(set) var typing: [String: Bool] = [:]
    private(set) var typed: [String: String] = [:]
    /// Counts the changes, for a view that also looks at what the draft says (`payload()`).
    private(set) var revision = 0

    var isTypingAny: Bool {
        typing.values.contains(true)
    }

    func isPicked(_ question: Question, _ option: QuestionOption) -> Bool {
        picked[question.text]?.contains(option.label) == true
    }

    func isTyping(_ question: Question) -> Bool {
        typing[question.text] == true
    }

    func typedText(_ question: Question) -> String {
        typed[question.text] ?? ""
    }

    /// Chooses `option` (or, for several, adds it or takes it away). It replaces an own answer, in the draft and here:
    /// the text that was typed is dropped, so it does not come back when the field is opened again.
    func select(_ question: Question, _ option: QuestionOption, in draft: AnswerDraft) {
        typing[question.text] = false
        typed[question.text] = nil
        if question.multiSelect {
            draft.toggle(question: question.text, label: option.label)
            var labels = picked[question.text] ?? []
            if let at = labels.firstIndex(of: option.label) { labels.remove(at: at) } else { labels.append(option.label) }
            picked[question.text] = labels
        } else {
            draft.choose(question: question.text, label: option.label)
            picked[question.text] = [option.label]
        }
        revision += 1
    }

    /// 「自己写一句…」 was tapped: the field opens. What was chosen stays until something is typed.
    func startTyping(_ question: Question) {
        typing[question.text] = true
        revision += 1
    }

    /// The own answer changed: it replaces whatever was chosen.
    func type(_ text: String, for question: Question, in draft: AnswerDraft) {
        typed[question.text] = text
        draft.freeText(question: question.text, text: text)
        picked[question.text] = []
        revision += 1
    }

    /// Puts what is shown into `draft`, a new one that replaced the old.
    func replay(into draft: AnswerDraft) {
        for question in RequestText.questions(draft.request.input) {
            if let text = typed[question.text], !text.isEmpty {
                draft.freeText(question: question.text, text: text)
            } else if question.multiSelect {
                for label in picked[question.text] ?? [] { draft.toggle(question: question.text, label: label) }
            } else if let label = picked[question.text]?.first {
                draft.choose(question: question.text, label: label)
            }
        }
        revision += 1
    }
}
