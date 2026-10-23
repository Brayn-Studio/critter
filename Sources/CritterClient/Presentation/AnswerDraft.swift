import CritterKit
import Foundation
import os

/// The answer being composed for one pending `request`. `payload()` mirrors the Mac's
/// `AskDecision.validate`: it is nil until the draft would be accepted. Safe to use from any thread
/// (Android `AnswerDraft`; a card and a notification button must not both answer).
public final class AnswerDraft: Sendable {
    public let request: BridgePending

    private enum Pick {
        case one(String)
        /// In the order tapped.
        case many([String])
        case text(String)
    }

    private struct State {
        var decision: String?
        var message: String?
        var picks: [String: Pick] = [:]
        var submitted = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let questions: [Question]

    public init(request: BridgePending) {
        self.request = request
        self.questions = RequestText.questions(request.input)
    }

    public func allow() {
        state.withLock { $0.decision = "allow"; $0.message = nil }
    }

    public func deny(message: String?) {
        state.withLock { $0.decision = "deny"; $0.message = Self.nonEmpty(message) }
    }

    public func approve() {
        state.withLock { $0.decision = "approve"; $0.message = nil }
    }

    public func revise(message: String) {
        state.withLock { $0.decision = "revise"; $0.message = Self.trimmed(message) }
    }

    /// Single-select: `label` becomes the whole answer to `question`.
    public func choose(question: String, label: String) {
        guard asks(question) else { return }
        state.withLock { $0.picks[question] = .one(label) }
    }

    /// Multi-select: adds `label` to the selection for `question`, or removes it if already there.
    public func toggle(question: String, label: String) {
        guard asks(question) else { return }
        state.withLock { s in
            var labels: [String] = []
            if case .many(let current)? = s.picks[question] { labels = current }
            if let at = labels.firstIndex(of: label) { labels.remove(at: at) } else { labels.append(label) }
            s.picks[question] = labels.isEmpty ? nil : .many(labels)
        }
    }

    /// "Other": `text` replaces any selection for `question`; blank text clears it.
    public func freeText(question: String, text: String) {
        guard asks(question) else { return }
        let text = Self.trimmed(text)
        state.withLock { $0.picks[question] = text.isEmpty ? nil : .text(text) }
    }

    /// What to send, or nil while the Mac would not accept it.
    public func payload() -> AnswerPayload? {
        let s = state.withLock { $0 }
        switch request.kind {
        case .permission:
            switch s.decision {
            case "allow": return AnswerPayload(decision: "allow")
            case "deny": return AnswerPayload(decision: "deny", message: s.message)
            default: return nil
            }
        case .plan:
            switch s.decision {
            case "approve": return AnswerPayload(decision: "approve")
            case "revise":
                guard let message = s.message, !message.isEmpty else { return nil }
                return AnswerPayload(decision: "revise", message: message)
            default: return nil
            }
        case .question:
            return questionPayload(s.picks)
        }
    }

    /// True only for the first call.
    public func markSubmitted() -> Bool {
        state.withLock { s in
            defer { s.submitted = true }
            return !s.submitted
        }
    }

    private func questionPayload(_ picks: [String: Pick]) -> AnswerPayload? {
        guard !questions.isEmpty else { return nil }
        var answers: [String: String] = [:]
        for question in questions {
            let text: String
            switch picks[question.text] {
            case .one(let label)?: text = label
            case .many(let labels)?: text = inOptionOrder(question, labels).joined(separator: BridgeProtocol.multiSelectSeparator)
            case .text(let free)?: text = free
            case nil: return nil
            }
            // As the Mac measures it: trimmed, not empty, at most 4000 characters.
            let measured = Self.trimmed(text)
            if measured.isEmpty || measured.count > Self.maxAnswerLength { return nil }
            answers[question.text] = text
        }
        return AnswerPayload(answers: answers)
    }

    /// `labels` in the order the question lists its options, whatever order they were tapped in; unlisted
    /// ones last, in the order tapped.
    private func inOptionOrder(_ question: Question, _ labels: [String]) -> [String] {
        let order = question.options.map(\.label)
        func rank(_ label: String) -> Int { order.firstIndex(of: label) ?? Int.max }
        return labels.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    private func asks(_ question: String) -> Bool {
        questions.contains { $0.text == question }
    }

    /// Characters, as the Mac counts them (`AskDecision.maxAnswerLength`).
    private static let maxAnswerLength = 4000

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        text.map(trimmed).flatMap { $0.isEmpty ? nil : $0 }
    }
}
