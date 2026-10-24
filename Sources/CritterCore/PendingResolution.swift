import Foundation

/// Retracts pending phone requests once the terminal (or the session ending) has settled them.
public enum PendingResolution {
    /// Tools whose `tool_input` grows (`answers`, `annotations`) once the terminal answers them, so
    /// the `matchKey` of the request no longer matches; for these, any request of the tool goes.
    private static let looseMatchTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// Runs on every event hook, so with no request waiting (the usual case, and always with the
    /// phone feature off) it stops at one directory listing: `toolInput` isn't even looked at,
    /// no match key is computed and no file is read.
    public static func apply(event: String, sessionId: String, toolName: String?, toolInput: @autoclosure () -> Any?, store: PendingStore) {
        switch event {
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            guard let toolName, store.hasRequests else { return }
            store.removeMatching(
                sessionId: sessionId, toolName: toolName,
                matchKey: MatchKey.compute(toolName: toolName, toolInput: toolInput())
            )
            if looseMatchTools.contains(toolName) {
                for request in store.readAll() where request.sessionId == sessionId && request.toolName == toolName {
                    store.remove(requestId: request.requestId)
                }
            }
        case "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd", "Interrupted":
            guard store.hasRequests else { return }
            store.removeAll(sessionId: sessionId)
        default:
            break
        }
    }
}
