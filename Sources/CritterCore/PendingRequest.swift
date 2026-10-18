import CryptoKit
import Foundation

public enum PendingKind: String, Codable, Sendable {
    case permission, question, plan

    public init(toolName: String) {
        switch toolName {
        case "AskUserQuestion": self = .question
        case "ExitPlanMode": self = .plan
        default: self = .permission
        }
    }
}

/// A prompt Claude Code is blocked on, published to `~/.critter/pending/<requestId>.json`
/// for the phone to answer. `input` is for display only (truncated); `matchKey` identifies the
/// request when the hook for the finished tool call has to retract it.
public struct PendingRequest: Codable, Sendable, Equatable {
    public var requestId: String
    public var sessionId: String
    public var kind: PendingKind
    public var toolName: String
    public var summary: String
    public var input: JSONValue
    public var matchKey: String
    public var createdAt: Int64
    public var expiresAt: Int64
    public var hookPid: Int32

    public init(
        requestId: String, sessionId: String, kind: PendingKind, toolName: String, summary: String,
        input: JSONValue, matchKey: String, createdAt: Int64, expiresAt: Int64, hookPid: Int32
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.kind = kind
        self.toolName = toolName
        self.summary = summary
        self.input = input
        self.matchKey = matchKey
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.hookPid = hookPid
    }
}

/// What the phone decided, written to `~/.critter/answers/<requestId>.json`. Which fields
/// are meaningful depends on the request's `kind`.
public struct AnswerPayload: Codable, Sendable, Equatable {
    public var decision: String?
    public var message: String?
    public var answers: [String: String]?

    public init(decision: String? = nil, message: String? = nil, answers: [String: String]? = nil) {
        self.decision = decision
        self.message = message
        self.answers = answers
    }
}

/// Identifies one tool call by what it was asked to do, so the `PostToolUse` hook can find
/// the request that was waiting on it.
public enum MatchKey {
    /// SHA-256 (lowercase hex) of `toolName`, a newline, and the key-sorted JSON of `toolInput`.
    public static func compute(toolName: String, toolInput: Any?) -> String {
        var serialized = ""
        if let toolInput, JSONSerialization.isValidJSONObject(toolInput),
           let data = try? JSONSerialization.data(withJSONObject: toolInput, options: [.sortedKeys, .withoutEscapingSlashes]) {
            serialized = String(decoding: data, as: UTF8.self)
        }
        let digest = SHA256.hash(data: Data((toolName + "\n" + serialized).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Pending requests under `pendingDir` and their answers under `answersDir`; files 0600,
/// directories 0700. Request ids are validated like session ids.
public struct PendingStore: Sendable {
    private let paths: CritterPaths

    public init(paths: CritterPaths) {
        self.paths = paths
    }

    public func write(_ request: PendingRequest) throws {
        guard let file = paths.sessionScopedFile(in: paths.pendingDir, sessionId: request.requestId) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try createPrivateDirectory(paths.pendingDir)
        try atomicWrite(JSONEncoder().encode(request), to: file, permissions: 0o600)
    }

    /// Every decodable request; corrupt files and hidden temp files are skipped.
    public func readAll() -> [PendingRequest] {
        files(in: paths.pendingDir).compactMap { try? JSONDecoder().decode(PendingRequest.self, from: (try? Data(contentsOf: $0)) ?? Data()) }
    }

    public func read(requestId: String) -> PendingRequest? {
        guard let file = paths.sessionScopedFile(in: paths.pendingDir, sessionId: requestId),
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(PendingRequest.self, from: data)
    }

    /// Removes the request and its answer.
    public func remove(requestId: String) {
        if let file = paths.sessionScopedFile(in: paths.pendingDir, sessionId: requestId) {
            try? FileManager.default.removeItem(at: file)
        }
        removeAnswer(requestId: requestId)
    }

    /// Removes only the answer, leaving the request waiting.
    public func removeAnswer(requestId: String) {
        if let file = paths.sessionScopedFile(in: paths.answersDir, sessionId: requestId) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func removeAll(sessionId: String) {
        for request in readAll() where request.sessionId == sessionId {
            remove(requestId: request.requestId)
        }
    }

    public func removeMatching(sessionId: String, toolName: String, matchKey: String) {
        for request in readAll()
        where request.sessionId == sessionId && request.toolName == toolName && request.matchKey == matchKey {
            remove(requestId: request.requestId)
        }
    }

    public func writeAnswer(_ answer: AnswerPayload, requestId: String) throws {
        guard let file = paths.sessionScopedFile(in: paths.answersDir, sessionId: requestId) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try createPrivateDirectory(paths.answersDir)
        try atomicWrite(JSONEncoder().encode(answer), to: file, permissions: 0o600)
    }

    public func readAnswer(requestId: String) -> AnswerPayload? {
        guard let file = paths.sessionScopedFile(in: paths.answersDir, sessionId: requestId),
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(AnswerPayload.self, from: data)
    }

    /// Drops requests that expired or whose hook process is gone, then answers with no request.
    public func sweep(now: Int64, isAlive: (Int32) -> Bool) {
        for request in readAll() where request.expiresAt < now || !isAlive(request.hookPid) {
            remove(requestId: request.requestId)
        }
        let live = Set(readAll().map(\.requestId))
        for file in files(in: paths.answersDir) where !live.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func files(in dir: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension == "json" }
    }

    private func createPrivateDirectory(_ dir: URL) throws {
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }
}
