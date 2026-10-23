import CritterClient
import CritterKit
import Observation

/// The answers being composed, by request id. The home screen keeps one, so a row's buttons and the card for the
/// same request work on the same draft (and the request is answered once). A question's draft has its
/// `QuestionChoices` beside it: what the card shows as chosen is kept here too, so it is the same each time the card is
/// opened.
@MainActor @Observable
final class AnswerDrafts {
    @ObservationIgnored private var drafts: [String: AnswerDraft] = [:]
    @ObservationIgnored private var choices: [String: QuestionChoices] = [:]
    /// How often each request's draft was replaced: a view that asks for a draft is redrawn when it is.
    private var generations: [String: Int] = [:]

    /// The draft for `request`, made on first use.
    func draft(for request: BridgePending) -> AnswerDraft {
        _ = generations[request.requestId]
        if let draft = drafts[request.requestId] { return draft }
        let draft = AnswerDraft(request: request)
        drafts[request.requestId] = draft
        return draft
    }

    /// What a question card shows as chosen for `requestId`, made on first use.
    func choices(for requestId: String) -> QuestionChoices {
        if let existing = choices[requestId] { return existing }
        let new = QuestionChoices()
        choices[requestId] = new
        return new
    }

    /// A fresh draft for the same request, after an answer did not get through (the old one counts as submitted). What
    /// the card shows as chosen is put into it, so the user can try again without choosing again.
    func renew(_ requestId: String) {
        guard let old = drafts[requestId] else { return }
        let new = AnswerDraft(request: old.request)
        choices[requestId]?.replay(into: new)
        drafts[requestId] = new
        generations[requestId, default: 0] += 1
    }

    /// Forgets the drafts of requests that are gone.
    func prune(keeping requestIds: Set<String>) {
        drafts = drafts.filter { requestIds.contains($0.key) }
        choices = choices.filter { requestIds.contains($0.key) }
        generations = generations.filter { requestIds.contains($0.key) }
    }
}
