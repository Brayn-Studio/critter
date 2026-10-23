import CritterClient
import Foundation

/// The one way an answer leaves the phone: the card's buttons and the home list's 「拒绝」「允许」 both come here
/// with the draft they share.
@MainActor
enum AnswerSubmit {
    /// Sends `draft`'s answer to the Mac and says what came of it.
    ///
    /// Returns nil when nothing was sent: the draft is not complete yet, or it was submitted before (a request is
    /// answered once per draft, `AnswerDraft.markSubmitted`). A caller that gets `.failed` should renew the draft
    /// (`AnswerDrafts.renew`) before letting the user try again.
    static func submit(draft: AnswerDraft, store: BridgeStore) async -> AnswerOutcome? {
        guard let payload = draft.payload(), draft.markSubmitted() else { return nil }
        let result = await store.send(.answer(requestId: draft.request.requestId, payload: payload))
        return AnswerOutcome(result)
    }
}
