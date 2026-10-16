import Foundation

/// All filesystem paths Clawd touches, with environment-variable overrides for testability.
public struct ClawdPaths: Sendable {
    public let clawdHome: URL
    public let claudeHome: URL

    public init(clawdHome: URL, claudeHome: URL) {
        self.clawdHome = clawdHome
        self.claudeHome = claudeHome
    }

    public var sessionsDir: URL { clawdHome.appendingPathComponent("sessions") }
    public var locksDir: URL { clawdHome.appendingPathComponent("locks") }
    public var appStatusFile: URL { clawdHome.appendingPathComponent("app.json") }
    public var binDir: URL { clawdHome.appendingPathComponent("bin") }
    public var skinsDir: URL { clawdHome.appendingPathComponent("skins") }

    public var claudeSessionsDir: URL { claudeHome.appendingPathComponent("sessions") }
    public var claudeIDEDir: URL { claudeHome.appendingPathComponent("ide") }

    /// `~/.clawd`, overridable with `CLAWD_HOME`; `~/.claude`, overridable with `CLAUDE_CONFIG_DIR`.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> ClawdPaths {
        let home = env["HOME"] ?? NSHomeDirectory()
        let clawdHome = env["CLAWD_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: home).appendingPathComponent(".clawd")
        let claudeHome = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: home).appendingPathComponent(".claude")
        return ClawdPaths(clawdHome: clawdHome, claudeHome: claudeHome)
    }

    // Pattern is a fixed, valid literal, so force-try is safe here.
    private static let sessionIdPattern: NSRegularExpression = try! NSRegularExpression(pattern: "^[A-Za-z0-9-]{1,128}$")

    /// The state file for a given session id, or nil if the id does not match the
    /// expected shape (guards against path traversal / injection via untrusted hook input).
    public func stateFile(sessionId: String) -> URL? {
        let range = NSRange(sessionId.startIndex..<sessionId.endIndex, in: sessionId)
        guard Self.sessionIdPattern.firstMatch(in: sessionId, range: range) != nil else { return nil }
        return sessionsDir.appendingPathComponent("\(sessionId).json")
    }
}
