import Foundation

/// Makes the bridge's snapshots from the app's state, filling in what `SnapshotBuilder` needs
/// read from disk: each session's git branch and, where the status line reported no context, an
/// estimate from its transcript. Both are cached -- a branch while its `HEAD` file's
/// modification time is the same, an estimate while the transcript's size and modification time
/// are -- and entries for what is no longer shown are dropped. Not thread-safe: the bridge uses
/// it on its own queue.
public final class SnapshotAssembler {
    /// How much of a transcript's end is read to estimate its context usage.
    public static let transcriptTailBytes = 64 * 1024

    /// The file-system reads, injectable for tests.
    public struct Dependencies {
        /// The `HEAD` file a cwd's branch comes from (`GitBranch.headFile`).
        public var headFile: (_ cwd: String, _ home: String) -> URL?
        public var modificationDate: (URL) -> Date?
        /// A cwd's branch (`GitBranch.read`).
        public var readBranch: (_ cwd: String, _ home: String) -> String?
        /// A file's size and modification time, nil if it can't be read.
        public var attributes: (_ path: String) -> (size: UInt64, modified: Date)?
        /// The end of a transcript of `size` bytes (`SnapshotAssembler.tail`).
        public var readTail: (_ path: String, _ size: UInt64) -> Data?

        public init(
            headFile: @escaping (String, String) -> URL?,
            modificationDate: @escaping (URL) -> Date?,
            readBranch: @escaping (String, String) -> String?,
            attributes: @escaping (String) -> (size: UInt64, modified: Date)?,
            readTail: @escaping (String, UInt64) -> Data?
        ) {
            self.headFile = headFile
            self.modificationDate = modificationDate
            self.readBranch = readBranch
            self.attributes = attributes
            self.readTail = readTail
        }

        public static var live: Dependencies {
            Dependencies(
                headFile: { GitBranch.headFile(cwd: $0, stopAt: $1) },
                modificationDate: { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date },
                readBranch: { GitBranch.read(cwd: $0, stopAt: $1) },
                attributes: { path in
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                          let size = (attributes[.size] as? NSNumber)?.uint64Value,
                          let modified = attributes[.modificationDate] as? Date else { return nil }
                    return (size, modified)
                },
                readTail: { SnapshotAssembler.tail(of: $0, size: $1) }
            )
        }
    }

    /// Keyed by cwd; valid while `HEAD`'s modification time is the same.
    private struct CachedBranch {
        var headModified: Date?
        var branch: String?
    }

    /// Keyed by transcript path; valid while its size and modification time are the same.
    private struct CachedEstimate {
        var size: UInt64
        var modified: Date
        var estimate: ContextEstimate?
    }

    private let home: String
    private let files: Dependencies
    private var branchCache: [String: CachedBranch] = [:]
    private var estimateCache: [String: CachedEstimate] = [:]

    public init(home: String, dependencies: Dependencies = .live) {
        self.home = home
        files = dependencies
    }

    public func build(
        sessions: [PetSession], skins: [String: String], statuses: [StatusLineRecord],
        pending: [PendingRequest], prefs: BridgePrefs, capabilities: [String: BridgeCapabilities] = [:]
    ) -> SnapshotBody {
        let reported = Set(statuses.filter { $0.contextUsedPercentage != nil }.map(\.sessionId))

        var branches: [String: String] = [:]
        let cwds = Set(sessions.map(\.cwd).filter { !$0.isEmpty })
        for cwd in cwds {
            if let branch = branch(cwd: cwd) { branches[cwd] = branch }
        }
        branchCache = branchCache.filter { cwds.contains($0.key) }

        var estimates: [String: ContextEstimate] = [:]
        var transcripts: Set<String> = []
        for session in sessions where !session.source.isCodex && !reported.contains(session.id) {
            guard let path = session.transcriptPath, !path.isEmpty else { continue }
            transcripts.insert(path)
            if let estimate = estimate(transcript: path) { estimates[session.id] = estimate }
        }
        estimateCache = estimateCache.filter { transcripts.contains($0.key) }

        return SnapshotBuilder.build(SnapshotInputs(
            sessions: sessions, skins: skins, statuses: statuses, pending: pending,
            branches: branches, estimates: estimates, prefs: prefs, home: home, capabilities: capabilities
        ))
    }

    /// Forgets everything cached (the bridge was switched off).
    public func reset() {
        branchCache = [:]
        estimateCache = [:]
    }

    private func branch(cwd: String) -> String? {
        let modified = files.headFile(cwd, home).flatMap(files.modificationDate)
        if let cached = branchCache[cwd], cached.headModified == modified { return cached.branch }
        let branch = files.readBranch(cwd, home)
        branchCache[cwd] = CachedBranch(headModified: modified, branch: branch)
        return branch
    }

    private func estimate(transcript path: String) -> ContextEstimate? {
        guard let (size, modified) = files.attributes(path) else { return nil }
        if let cached = estimateCache[path], cached.size == size, cached.modified == modified { return cached.estimate }
        let estimate = files.readTail(path, size).flatMap(ContextUsage.lastUsage(inTranscriptTail:))
        estimateCache[path] = CachedEstimate(size: size, modified: modified, estimate: estimate)
        return estimate
    }

    /// The last `transcriptTailBytes` of a file. `ContextUsage.lastUsage` drops the first line
    /// as possibly cut off, so when the whole file fits, a newline goes in front of it.
    public static func tail(of path: String, size: UInt64) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let offset = size > UInt64(transcriptTailBytes) ? size - UInt64(transcriptTailBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil, var data = try? handle.readToEnd() else { return nil }
        if offset == 0 { data.insert(UInt8(ascii: "\n"), at: 0) }
        return data
    }
}
