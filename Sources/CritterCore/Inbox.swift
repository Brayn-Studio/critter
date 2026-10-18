import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Where to send text so it reaches a session as if typed: the messaging socket Claude Code
/// exposes to its hooks (`CLAUDE_CODE_MESSAGING_SOCKET` / `_TOKEN`), recorded at SessionStart.
public struct InboxRecord: Codable, Sendable, Equatable {
    public var sessionId: String
    public var socketPath: String
    public var token: String

    public init(sessionId: String, socketPath: String, token: String) {
        self.sessionId = sessionId
        self.socketPath = socketPath
        self.token = token
    }
}

/// One 0600 file per session under `inboxDir` (0700): it holds a token that lets whoever reads it
/// speak as the user.
public struct InboxStore: Sendable {
    private let paths: CritterPaths

    public init(paths: CritterPaths) {
        self.paths = paths
    }

    public func write(_ record: InboxRecord) throws {
        guard let file = paths.sessionScopedFile(in: paths.inboxDir, sessionId: record.sessionId) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(
            at: paths.inboxDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try atomicWrite(JSONEncoder().encode(record), to: file, permissions: 0o600)
    }

    public func read(sessionId: String) -> InboxRecord? {
        guard let file = paths.sessionScopedFile(in: paths.inboxDir, sessionId: sessionId),
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(InboxRecord.self, from: data)
    }

    public func delete(sessionId: String) {
        guard let file = paths.sessionScopedFile(in: paths.inboxDir, sessionId: sessionId) else { return }
        try? FileManager.default.removeItem(at: file)
    }
}

/// Delivers a line of text to a session's messaging socket.
public enum InboxSender {
    public enum Failure: Error, Equatable { case notAllowedPath, connectFailed, writeFailed }

    /// Only Claude Code's own socket directory: the path comes from a file on disk, so it must
    /// not be able to point this at an arbitrary socket.
    public static let allowedPath = #"^(/private)?/tmp/cc-socks(-[0-9]+)?/[^/]+\.sock$"#

    /// Connects, writes the auth line then the user message line, and closes. Does not wait for a reply.
    public static func send(text: String, to record: InboxRecord) throws {
        guard record.socketPath.range(of: allowedPath, options: .regularExpression) != nil else {
            throw Failure.notAllowedPath
        }
        let lines: [[String: Any]] = [
            ["type": "auth", "token": record.token],
            ["type": "user", "message": ["role": "user", "content": text]],
        ]
        var payload = Data()
        for line in lines {
            guard let data = try? JSONSerialization.data(withJSONObject: line) else { throw Failure.writeFailed }
            payload.append(data)
            payload.append(0x0A)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.connectFailed }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(record.socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure.connectFailed }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            for (i, byte) in pathBytes.enumerated() { buffer[i] = byte }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure.connectFailed }

        var offset = 0
        while offset < payload.count {
            let written = payload.withUnsafeBytes { write(fd, $0.baseAddress! + offset, payload.count - offset) }
            guard written > 0 else { throw Failure.writeFailed }
            offset += written
        }
    }
}
