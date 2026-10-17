import Foundation

/// Where a Claude Code session originated from, derived from the hook's `source`/entrypoint field.
public enum SessionSource: String, Codable, Sendable {
    case terminal
    case vscode
    case desktop
    case other

    public init(entrypoint: String?) {
        switch entrypoint {
        case "cli": self = .terminal
        case "claude-vscode": self = .vscode
        case "claude-desktop": self = .desktop
        default: self = .other
        }
    }

    public var label: String {
        switch self {
        case .terminal: return "终端"
        case .vscode: return "VS Code"
        case .desktop: return "Desktop"
        case .other: return "其他"
        }
    }

    /// Sessions started by SDK-driven entrypoints (e.g. "sdk-cli") are not shown as pets.
    public static func isExcluded(entrypoint: String?) -> Bool {
        entrypoint?.hasPrefix("sdk") ?? false
    }
}
