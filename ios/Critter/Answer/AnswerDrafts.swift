import CritterClient
import CritterKit
import Observation

/// The answers being composed, by request id. The home screen keeps one, so a row's buttons and the card for the
/// same request work on the same draft (and the request is answered once).
@MainActor @Observable
final class AnswerDrafts {
    @ObservationIgnored private var drafts: [String: AnswerDraft] = [:]
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

    /// A fresh draft for the same request, after an answer did not get through (the old one counts as submitted).
    func renew(_ requestId: String) {
        guard let old = drafts[requestId] else { return }
        drafts[requestId] = AnswerDraft(request: old.request)
        generations[requestId, default: 0] += 1
    }

    /// Forgets the drafts of requests that are gone.
    func prune(keeping requestIds: Set<String>) {
        drafts = drafts.filter { requestIds.contains($0.key) }
        generations = generations.filter { requestIds.contains($0.key) }
    }
}
