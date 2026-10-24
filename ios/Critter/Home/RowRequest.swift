import CritterClient
import CritterKit
import Foundation

/// The request a session's row offers (Android `CardRequest`): the session's oldest one, what it says in a few words,
/// and how many more wait behind it. Sessions that cannot be answered from the phone (Codex without a verified
/// owner) offer none, so a button never acts on a request the row does not show.
struct RowRequest: Equatable {
    let request: BridgePending
    /// "想 swift test", "问：部署到哪个环境？", "计划等你批准".
    let what: String
    /// The command or path of a permission request.
    let command: String?
    let more: Int

    /// Only a lone permission request is answered in place; anything else opens the card.
    var isInline: Bool { more == 0 && request.kind == .permission }

    /// The same as the board's `CardRequest`, for the rules they share (`HomeRules.inlineAnswer`).
    var card: CardRequest {
        CardRequest(request: request, what: what, detail: command, more: more)
    }

    /// Every session's row request, by session id.
    static func all(in body: SnapshotBody?) -> [String: RowRequest] {
        guard let body else { return [:] }
        let answerable = body.pending.filter { request in
            body.sessions.first { $0.id == request.sessionId }.map(SessionText.supportsAnswers) ?? true
        }
        var result: [String: RowRequest] = [:]
        for (sessionId, requests) in Dictionary(grouping: answerable, by: \.sessionId) {
            guard let oldest = requests.min(by: { $0.createdAt < $1.createdAt }) else { continue }
            let summary = [oldest.summary, oldest.toolName].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let what: String
            switch oldest.kind {
            case .permission: what = summary.map { "想 \($0)" } ?? "想执行一个操作"
            case .question: what = summary.map { "问：\($0)" } ?? "有问题要问你"
            case .plan: what = "计划等你批准"
            }
            let command = oldest.kind == .permission ? RequestText.permissionBody(oldest.input) : nil
            result[sessionId] = RowRequest(request: oldest, what: what, command: command, more: requests.count - 1)
        }
        return result
    }
}
