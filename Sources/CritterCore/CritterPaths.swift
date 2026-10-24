import Foundation

/// All filesystem paths Critter touches, with environment-variable overrides for testability.
public struct CritterPaths: Sendable {
    public let critterHome: URL
    public let claudeHome: URL
    public let codexHome: URL

    public init(critterHome: URL, claudeHome: URL, codexHome: URL? = nil) {
        self.critterHome = critterHome
        self.claudeHome = claudeHome
        self.codexHome = codexHome ?? claudeHome.deletingLastPathComponent().appendingPathComponent(".codex")
    }

    public var sessionsDir: URL { critterHome.appendingPathComponent("sessions") }
    public var locksDir: URL { critterHome.appendingPathComponent("locks") }
    public var appStatusFile: URL { critterHome.appendingPathComponent("app.json") }
    public var binDir: URL { critterHome.appendingPathComponent("bin") }
    public var skinsDir: URL { critterHome.appendingPathComponent("skins") }
    public var statusDir: URL { critterHome.appendingPathComponent("status") }
    public var pendingDir: URL { critterHome.appendingPathComponent("pending") }
    public var answersDir: URL { critterHome.appendingPathComponent("answers") }
    public var inboxDir: URL { critterHome.appendingPathComponent("inbox") }
    public var bridgeDir: URL { critterHome.appendingPathComponent("bridge") }
    /// The APNs key (`.p8`) and the iPhone push setup: 0700, files 0600, never anywhere else.
    public var apnsDir: URL { bridgeDir.appendingPathComponent("apns") }
    public var backupDir: URL { critterHome.appendingPathComponent("backup") }

    public var claudeSessionsDir: URL { claudeHome.appendingPathComponent("sessions") }
    public var claudeIDEDir: URL { claudeHome.appendingPathComponent("ide") }
    public var claudeSettingsFile: URL { claudeHome.appendingPathComponent("settings.json") }
    public var codexSessionsDir: URL { codexHome.appendingPathComponent("sessions") }

    /// `~/.critter`, overridable with `CRITTER_HOME`; `~/.claude`, overridable with `CLAUDE_CONFIG_DIR`.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> CritterPaths {
        let home = env["HOME"] ?? NSHomeDirectory()
        let critterHome = env["CRITTER_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: home).appendingPathComponent(".critter")
        let claudeHome = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: home).appendingPathComponent(".claude")
        let codexHome = env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: home).appendingPathComponent(".codex")
        return CritterPaths(critterHome: critterHome, claudeHome: claudeHome, codexHome: codexHome)
    }

    // Pattern is a fixed, valid literal, so force-try is safe here.
    private static let sessionIdPattern: NSRegularExpression = try! NSRegularExpression(pattern: "^[A-Za-z0-9-]{1,128}$")

    /// The state file for a given session id, or nil if the id does not match the
    /// expected shape (guards against path traversal / injection via untrusted hook input).
    public func stateFile(sessionId: String) -> URL? {
        sessionScopedFile(in: sessionsDir, sessionId: sessionId)
    }

    /// Whether the absolute `path` names a file somewhere under one of `roots` -- after `..`
    /// and symlinks are resolved, so neither can lead out of them.
    public static func isFile(_ path: String, under roots: [URL]) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath().path
        return roots.contains { root in
            let root = root.standardizedFileURL.resolvingSymlinksInPath().path
            return parent == root || parent.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    /// `<dir>/<sessionId>.json`, or nil if the id does not match the expected shape.
    public func sessionScopedFile(in dir: URL, sessionId: String) -> URL? {
        let range = NSRange(sessionId.startIndex..<sessionId.endIndex, in: sessionId)
        guard Self.sessionIdPattern.firstMatch(in: sessionId, range: range) != nil else { return nil }
        return dir.appendingPathComponent("\(sessionId).json")
    }
}
