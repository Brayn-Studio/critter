import Foundation

/// Turns a phone's answer into the JSON a `PermissionRequest` hook prints, and checks that
/// an answer is one Claude Code could act on before it is used.
public enum AskDecision {
    public static let defaultDenyMessage = "用户在手机上拒绝了"

    /// What Claude reads for a refusal with a reason. The reason alone ("等会") reads like the command's own error (on an
    /// iPhone Claude retried it), so the message says the user refused, that nothing ran, and gives the reason as theirs.
    public static func denyMessage(reason: String) -> String {
        reason.isEmpty ? defaultDenyMessage : "用户在手机上拒绝了，没有执行。用户的理由：\(reason)"
    }

    /// What Claude reads when a plan is sent back: the user's changes, said to be theirs.
    public static func reviseMessage(_ changes: String) -> String {
        "用户在手机上没有批准这个计划，要求修改：\(changes)"
    }

    /// Keys whose strings are shown in full; everything else is cut at `displayLimit`.
    public static let untruncatedKeys: Set<String> = ["command", "plan", "question", "file_path", "notebook_path", "url"]
    /// How a multi-select question's chosen option labels are joined into its one answer
    /// string: "A, B". Verified against Claude Code 2.1.302 (spec section 13): Claude received
    /// both labels. The Mac passes the string through unchanged (but for trimming its ends);
    /// phones build it.
    public static let multiSelectSeparator = BridgeProtocol.multiSelectSeparator
    static let displayLimit = 4096
    static let maxAnswerLength = 4000

    /// `toolInput` for display: long strings are cut to 4096 characters plus "…", except under `untruncatedKeys`.
    public static func displayInput(_ toolInput: Any?) -> JSONValue {
        truncated(JSONValue(any: toolInput), key: nil)
    }

    private static func truncated(_ value: JSONValue, key: String?) -> JSONValue {
        switch value {
        case .string(let s):
            if let key, untruncatedKeys.contains(key) { return value }
            return s.count > displayLimit ? .string(String(s.prefix(displayLimit)) + "…") : value
        case .array(let items): return .array(items.map { truncated($0, key: key) })
        case .object(let dict): return .object(dict.reduce(into: [:]) { $0[$1.key] = truncated($1.value, key: $1.key) })
        default: return value
        }
    }

    public static func validate(_ answer: AnswerPayload, kind: PendingKind, toolInput: [String: Any]) -> Bool {
        switch kind {
        case .permission:
            return answer.decision == "allow" || answer.decision == "deny"
        case .question:
            // Exactly the request's questions, every one of them: Claude Code takes the answers
            // as the user's whole reply, so a partial one would leave a question unanswered.
            guard let answers = answer.answers, !answers.isEmpty else { return false }
            let questions = ((toolInput["questions"] as? [[String: Any]]) ?? []).compactMap { $0["question"] as? String }
            guard Set(answers.keys) == Set(questions) else { return false }
            return answers.values.allSatisfy { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && trimmed.count <= maxAnswerLength
            }
        case .plan:
            switch answer.decision {
            case "approve": return true
            case "revise": return !(answer.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default: return false
            }
        }
    }

    /// The hook's stdout JSON, or nil when the answer is not valid for `kind`.
    public static func output(kind: PendingKind, toolInput: [String: Any], answer: AnswerPayload) -> Data? {
        guard validate(answer, kind: kind, toolInput: toolInput) else { return nil }
        var decision: [String: Any]
        switch kind {
        case .permission:
            if answer.decision == "allow" {
                decision = ["behavior": "allow"]
            } else {
                decision = ["behavior": "deny", "message": denyMessage(reason: (answer.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines))]
            }
        case .question:
            // Trimmed, as they were checked: what goes out is what was measured.
            var updated = toolInput
            updated["answers"] = answer.answers?.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            decision = ["behavior": "allow", "updatedInput": updated]
        case .plan:
            if answer.decision == "approve" {
                decision = ["behavior": "allow", "updatedInput": toolInput]
            } else {
                decision = ["behavior": "deny", "message": reviseMessage((answer.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines))]
            }
        }
        let root: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
