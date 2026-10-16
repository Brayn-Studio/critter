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

    public init(
        pid: Int32,
        sessionId: String,
        cwd: String,
        startedAt: Int64?,
        entrypoint: String?,
        kind: String?,
        name: String?
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.startedAt = startedAt
        self.entrypoint = entrypoint
        self.kind = kind
        self.name = name
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

/// Finds the real `claude` process behind a hook invocation: the registry is authoritative
/// when it has the session, otherwise we walk up from the hook's parent pid looking for a
/// Claude executable. Never falls back to guessing the parent shell is Claude.
public enum ClaudeProcessLocator {
    public static func locate(
        sessionId: String,
        registry: [RegistryEntry],
        hookParentPid: Int32
    ) -> (pid: Int32, startTime: Int64?)? {
        if let match = registry.first(where: { $0.sessionId == sessionId }) {
            return (match.pid, ProcessTools.startTime(of: match.pid))
        }
        let candidates = [hookParentPid] + ProcessTools.ancestors(of: hookParentPid, maxDepth: 4)
        for pid in candidates {
            if let path = ProcessTools.executablePath(of: pid), ProcessTools.isClaudeExecutable(path: path) {
                return (pid, ProcessTools.startTime(of: pid))
            }
        }
        return nil
    }
}
