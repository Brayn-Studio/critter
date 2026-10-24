import Foundation

/// The client hosting an agent session. A known Codex session can have an unknown client.
public enum SessionSource: String, Codable, Sendable {
    case terminal
    case vscode
    case desktop
    case other
    case codex
    case codexTerminal = "codex_terminal"
    case codexVSCode = "codex_vscode"
    case codexDesktop = "codex_desktop"
    case kimiDesktop = "kimi_desktop"
    case kimiTerminal = "kimi_terminal"
    case deepseekDesktop = "deepseek_desktop"

    public init(entrypoint: String?, sessionId: String? = nil, transcriptPath: String? = nil) {
        switch entrypoint {
        case "cli": self = .terminal
        case "claude-vscode": self = .vscode
        case "claude-desktop": self = .desktop
        default:
            switch entrypoint?.lowercased().replacingOccurrences(of: "_", with: "-") {
            case "codex-cli", "codex-terminal", "codex-cli-rs": self = .codexTerminal
            case "codex-vscode": self = .codexVSCode
            case "codex-desktop", "codex-app": self = .codexDesktop
            case "codex": self = .codex
            case "kimi-desktop": self = .kimiDesktop
            case "kimi-cli": self = .kimiTerminal
            case "deepseek-desktop": self = .deepseekDesktop
            default: self = .other
            }
        }
        if !isCodex, let sessionId, Self.codexConversationID(sessionId: sessionId, transcriptPath: transcriptPath) != nil {
            self = .codex
        }
    }

    public var label: String {
        switch self {
        case .terminal: return "终端"
        case .vscode: return "VS Code"
        case .desktop: return "Desktop"
        case .other: return "其他"
        case .codex: return "Codex"
        case .codexTerminal: return "Codex · 终端"
        case .codexVSCode: return "Codex · VS Code"
        case .codexDesktop: return "Codex · Desktop"
        case .kimiDesktop: return "Kimi · Desktop"
        case .kimiTerminal: return "Kimi · 终端"
        case .deepseekDesktop: return "DeepSeek · Desktop"
        }
    }

    public var isCodex: Bool {
        switch self {
        case .codex, .codexTerminal, .codexVSCode, .codexDesktop: return true
        default: return false
        }
    }

    public var isKimi: Bool {
        self == .kimiDesktop || self == .kimiTerminal
    }

    public var isDeepSeek: Bool {
        self == .deepseekDesktop
    }

    /// Kimi Code and DeepSeek Harness: not Claude, not Codex, and with no Claude registry entry to consult.
    public var isAgentApp: Bool {
        isKimi || isDeepSeek
    }

    /// A namespaced id is conclusive. Legacy bare UUIDs need a matching Codex rollout
    /// filename under the conventional sessions directory, so Claude UUIDs stay Claude.
    public static func codexConversationID(sessionId: String, transcriptPath: String? = nil) -> String? {
        if sessionId.hasPrefix("codex-") {
            let id = String(sessionId.dropFirst(6))
            return UUID(uuidString: id) == nil ? nil : id
        }
        guard UUID(uuidString: sessionId) != nil, let transcriptPath, transcriptPath.hasPrefix("/") else { return nil }
        let file = URL(fileURLWithPath: transcriptPath).standardizedFileURL
        let components = file.pathComponents
        guard components.indices.dropLast().contains(where: { components[$0] == ".codex" && components[$0 + 1] == "sessions" }),
              file.lastPathComponent.hasPrefix("rollout-"),
              file.lastPathComponent.lowercased().hasSuffix("-" + sessionId.lowercased() + ".jsonl") else { return nil }
        return sessionId
    }

    /// Sessions started by SDK-driven entrypoints (e.g. "sdk-cli") are not shown as pets.
    public static func isExcluded(entrypoint: String?) -> Bool {
        entrypoint?.hasPrefix("sdk") ?? false
    }
}
