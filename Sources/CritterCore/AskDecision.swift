import Foundation

/// Turns a phone's answer into the JSON a `PermissionRequest` hook prints, and checks that
/// an answer is one Claude Code could act on before it is used.
public enum AskDecision {
    public static let defaultDenyMessage = "用户在手机上拒绝了"
    /// Keys whose strings are shown in full; everything else is cut at `displayLimit`.
    public static let untruncatedKeys: Set<String> = ["command", "plan", "question", "file_path", "notebook_path", "url"]
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
            guard let answers = answer.answers, !answers.isEmpty else { return false }
            let questions = ((toolInput["questions"] as? [[String: Any]]) ?? []).compactMap { $0["question"] as? String }
            return answers.allSatisfy { key, value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return questions.contains(key) && !trimmed.isEmpty && trimmed.count <= maxAnswerLength
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
                let message = (answer.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                decision = ["behavior": "deny", "message": message.isEmpty ? defaultDenyMessage : message]
            }
        case .question:
            var updated = toolInput
            updated["answers"] = answer.answers
            decision = ["behavior": "allow", "updatedInput": updated]
        case .plan:
            if answer.decision == "approve" {
                decision = ["behavior": "allow", "updatedInput": toolInput]
            } else {
                decision = ["behavior": "deny", "message": answer.message ?? ""]
            }
        }
        let root: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
