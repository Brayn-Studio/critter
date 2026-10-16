import Foundation

/// One entry from `~/.claude/sessions/*.json`: a running `claude` process the CLI itself
/// knows about. Only the fields Clawd needs are declared; everything else in the JSON
/// (including `authToken`-adjacent fields on other record types) is ignored by decoding.
public struct RegistryEntry: Sendable, Equatable, Decodable {
    public var pid: Int32
    public var sessionId: String
    public var cwd: String
    public var startedAt: Int64?
    public var entrypoint: String?
    public var kind: String?
    public var name: String?
    /// Milliseconds since epoch of the entry's last rewrite (Claude rewrites it on every
    /// status change). Absent until the first one -- and in older CLI versions.
    public var updatedAt: Int64?

    public init(
        pid: Int32,
        sessionId: String,
        cwd: String,
        startedAt: Int64?,
        entrypoint: String?,
        kind: String?,
        name: String?,
        updatedAt: Int64? = nil
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.startedAt = startedAt
        self.entrypoint = entrypoint
        self.kind = kind
        self.name = name
        self.updatedAt = updatedAt
    }
}

/// One entry from `~/.claude/ide/*.lock`: an editor (VS Code, etc.) that registered itself
/// for IDE integration. `authToken` is deliberately never parsed or stored.
public struct IDELock: Sendable, Equatable, Decodable {
    public var pid: Int32?
    public var workspaceFolders: [String]
    public var ideName: String?

    public init(pid: Int32?, workspaceFolders: [String], ideName: String?) {
        self.pid = pid
        self.workspaceFolders = workspaceFolders
        self.ideName = ideName
    }
}

/// Read-only access to the Claude Code CLI's own registry directories. Every entry point
/// tolerates missing fields, wrong types, and fully corrupt files by simply skipping them.
public enum ClaudeRegistry {
    public static func entries(in dir: URL) -> [RegistryEntry] {
        jsonFiles(in: dir, extension: "json").compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return parseEntry(data)
        }
    }

    public static func parseEntry(_ data: Data) -> RegistryEntry? {
        try? JSONDecoder().decode(RegistryEntry.self, from: data)
    }

    public static func ideLocks(in dir: URL) -> [IDELock] {
        jsonFiles(in: dir, extension: "lock").compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(IDELock.self, from: data)
        }
    }

    private static func jsonFiles(in dir: URL, extension ext: String) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return items.filter { $0.pathExtension == ext }
    }
}

/// The `claude` process behind a hook invocation, and its registry entry if it has one.
public struct LocatedClaude: Equatable, Sendable {
    public var pid: Int32
    /// Seconds since epoch (`ProcessTools.startTime`), recorded to detect pid reuse later.
    public var startTime: Int64?
    /// The registry entry for `pid` (source of `entrypoint`), nil if Claude never wrote one.
    public var entry: RegistryEntry?

    public init(pid: Int32, startTime: Int64?, entry: RegistryEntry?) {
        self.pid = pid
        self.startTime = startTime
        self.entry = entry
    }
}

/// Finds the real `claude` process behind a hook invocation. The hook's own parent chain
/// comes first (Claude runs its hooks as children -- confirmed in the 2026-10-17 spike), so
/// a leftover registry entry for the same session (a killed process, before `claude
/// --resume` reopened it) can never win. Only without a Claude ancestor does the registry
/// decide: its live entries for the session (not dead, pid not reused), newest first.
/// Never guesses that a non-Claude parent is Claude.
public enum ClaudeProcessLocator {
    public static let ancestorDepth = 4

    public static func locate(
        sessionId: String,
        registry: [RegistryEntry],
        hookParentPid: Int32,
        processes: ProcessInspecting = SystemProcesses()
    ) -> LocatedClaude? {
        let candidates = [hookParentPid] + processes.ancestors(of: hookParentPid, maxDepth: ancestorDepth)
        if let pid = candidates.first(where: { pid in
            processes.executablePath(of: pid).map(ProcessTools.isClaudeExecutable(path:)) ?? false
        }) {
            let entry = registry.first { $0.pid == pid && $0.sessionId == sessionId } ?? registry.first { $0.pid == pid }
            return LocatedClaude(pid: pid, startTime: processes.startTime(of: pid), entry: entry)
        }

        let live = registry.filter { entry in
            entry.sessionId == sessionId
                && !StartupCleanup.isDead(entry: entry, isAlive: processes.isAlive, startTime: processes.startTime)
        }
        guard let newest = live.max(by: { ($0.startedAt ?? .min) < ($1.startedAt ?? .min) }) else { return nil }
        return LocatedClaude(pid: newest.pid, startTime: processes.startTime(of: newest.pid), entry: newest)
    }
}
