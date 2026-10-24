import Foundation

/// Fixed bubble copy used by `StateReducer` for events whose text doesn't depend on
/// tool/message content.
public enum BubbleText {
    public static let thinking = "思考中…"
    public static let done = "做完了"
    public static let askQuestion = "Claude 在问你问题"
    /// "Claude 在问你问题", or the agent app's own name for sessions from Kimi Code / DeepSeek Harness.
    public static func askQuestion(entrypoint: String?) -> String {
        if entrypoint?.hasPrefix("kimi-") == true { return "Kimi 在问你问题" }
        if entrypoint?.hasPrefix("deepseek-") == true { return "DeepSeek 在问你问题" }
        return askQuestion
    }
    public static let planApproval = "等你确认计划"
    public static let confirmPrefix = "需要你确认："
    public static let errorPrefix = "出错了："
}

/// Builds the short strings shown in the pet's speech bubble: one-line tool activity
/// summaries, permission-request summaries, and the truncation rules shared by both.
public enum ToolSummary {
    /// A short description of what `toolName` is doing, derived from its `input`. Always ≤ 40 characters.
    public static func activity(toolName: String, input: JSONValue?) -> String {
        let raw: String
        switch toolName {
        case "Bash":
            let command = input?["command"]?.stringValue ?? ""
            let firstLine = command.components(separatedBy: "\n").first ?? command
            raw = "Bash: \(firstLine)"
        case "Edit", "MultiEdit", "NotebookEdit":
            raw = "编辑 \(fileName(input))"
        case "Write":
            raw = "写入 \(fileName(input))"
        case "Read":
            raw = "读取 \(fileName(input))"
        case "Grep", "Glob":
            raw = "搜索 \(input?["pattern"]?.stringValue ?? "")"
        case "WebFetch":
            let url = input?["url"]?.stringValue ?? ""
            raw = "联网：\(URLComponents(string: url)?.host ?? url)"
        case "WebSearch":
            raw = "联网：\(input?["query"]?.stringValue ?? "")"
        case "Agent", "Task":
            raw = "子任务：\(input?["description"]?.stringValue ?? "")"
        case "Skill":
            raw = "技能：\(input?["skill"]?.stringValue ?? "")"
        default:
            if toolName.hasPrefix("mcp__") {
                raw = "MCP: \(toolName.components(separatedBy: "__").last ?? toolName)"
            } else {
                raw = toolName
            }
        }
        return truncate(raw, max: 40)
    }

    /// The text shown while waiting on a permission prompt, e.g. "需要你确认：Bash(npm test)". Always ≤ 40 characters.
    public static func permission(toolName: String, input: JSONValue?) -> String {
        let argSummary: String
        if let command = input?["command"]?.stringValue {
            argSummary = command
        } else if input?["file_path"]?.stringValue != nil {
            argSummary = fileName(input)
        } else if let url = input?["url"]?.stringValue {
            argSummary = url
        } else {
            argSummary = ""
        }
        return truncate("\(BubbleText.confirmPrefix)\(toolName)(\(argSummary))", max: 40)
    }

    /// The substring of `s` up to and including the first sentence terminator
    /// (`。！？.!?` or newline), then passed through `truncate(_:max:)`.
    public static func firstSentence(_ s: String, max: Int) -> String {
        let terminators: Set<Character> = ["。", "！", "？", ".", "!", "?", "\n"]
        if let idx = s.firstIndex(where: { terminators.contains($0) }) {
            return truncate(String(s[s.startIndex...idx]), max: max)
        }
        return truncate(s, max: max)
    }

    /// Collapses all whitespace runs to a single space and trims the ends, then limits the
    /// result to `max` `Character`s, replacing the last character with "…" when it was longer.
    public static func truncate(_ s: String, max: Int) -> String {
        let collapsed = collapseWhitespace(s)
        guard collapsed.count > max else { return collapsed }
        guard max > 0 else { return "" }
        return String(collapsed.prefix(max - 1)) + "…"
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func fileName(_ input: JSONValue?) -> String {
        guard let path = input?["file_path"]?.stringValue, !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}
