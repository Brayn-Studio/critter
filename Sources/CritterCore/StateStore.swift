import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum StateStoreError: Error, Sendable, Equatable {
    case invalidSessionId(String)
}

/// Writes `data` to `url` by first writing a same-directory hidden temp file and renaming
/// it into place, so readers never observe a partial write. Shared by `StateStore` and
/// `AppStatusStore`.
func atomicWrite(_ data: Data, to url: URL, permissions: Int? = nil) throws {
    let dir = url.deletingLastPathComponent()
    let tmpURL = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(getpid())-\(Int.random(in: 0...Int.max))")
    try data.write(to: tmpURL)
    if let permissions {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: tmpURL.path)
    }
    let renameStatus = tmpURL.withUnsafeFileSystemRepresentation { tmpPath in
        url.withUnsafeFileSystemRepresentation { destPath in
            rename(tmpPath!, destPath!)
        }
    }
    guard renameStatus == 0 else {
        let savedErrno = errno
        try? FileManager.default.removeItem(at: tmpURL)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(savedErrno))
    }
}

/// Reads and writes `~/.critter/sessions/<id>.json` session records: atomically, guarded by a
/// per-session `flock`, and never letting a stale event (lower `eventTime`) overwrite a newer one.
public struct StateStore: Sendable {
    private let paths: CritterPaths

    public init(paths: CritterPaths) {
        self.paths = paths
    }

    /// Locks the session, reads its current record, lets `body` decide the next action, and
    /// applies it. Throws only for a malformed `sessionId`; filesystem failures inside the
    /// critical section are not expected in normal operation and are allowed to propagate.
    public func update(sessionId: String, _ body: (SessionRecord?) -> ReducerAction) throws {
        guard let stateFile = paths.stateFile(sessionId: sessionId) else {
            throw StateStoreError.invalidSessionId(sessionId)
        }
        try FileManager.default.createDirectory(at: paths.sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.locksDir, withIntermediateDirectories: true)

        let lockFile = paths.locksDir.appendingPathComponent("\(sessionId).lock")
        let fd = open(lockFile.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }

        let previous = readRecord(at: stateFile)
        switch body(previous) {
        case .ignore:
            return
        case .delete:
            // Never unlink the lock file: flock binds to the vnode, not the path. If we
            // unlinked it here, a concurrent open(O_CREAT) on the same path would create a
            // fresh inode and hand out a "lock" on it immediately, defeating mutual
            // exclusion with whoever (if anyone) still held the old one.
            try? FileManager.default.removeItem(at: stateFile)
        case .write(let newRecord):
            if let previous, newRecord.eventTime < previous.eventTime {
                return
            }
            try atomicWrite(JSONEncoder().encode(newRecord), to: stateFile)
        }
    }

    public func read(sessionId: String) -> SessionRecord? {
        guard let stateFile = paths.stateFile(sessionId: sessionId) else { return nil }
        return readRecord(at: stateFile)
    }

    /// Every decodable session record in `sessionsDir`. Corrupt files and hidden temp files
    /// (left behind by an interrupted write) are skipped rather than causing a failure.
    public func readAll() -> [SessionRecord] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: paths.sessionsDir, includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return entries.compactMap { url in
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), name.hasSuffix(".json") else { return nil }
            return readRecord(at: url)
        }
    }

    /// Routed through `update` so it serializes with any in-flight `update` for the same
    /// session (e.g. a hook process writing state) instead of racing it unlocked. The only
    /// way `update` throws is an invalid `sessionId`, which this method simply ignores
    /// (matching its non-throwing signature), consistent with `read`/`stateFile` treating a
    /// malformed id as "no such session" rather than an error.
    public func delete(sessionId: String) {
        try? update(sessionId: sessionId) { _ in .delete }
    }

    private func readRecord(at url: URL) -> SessionRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionRecord.self, from: data)
    }
}
