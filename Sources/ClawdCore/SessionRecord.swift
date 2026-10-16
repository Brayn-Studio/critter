import Foundation

/// On-disk representation of a single session's pet state (`~/.clawd/sessions/<id>.json`).
/// Schema version 1.
public struct SessionRecord: Codable, Sendable, Equatable {
    public var schema: Int
    public var sessionId: String
    public var cwd: String
    public var transcriptPath: String?
    public var state: PetState
    public var detail: String?
    public var lastEvent: String
    /// Milliseconds since epoch, time of the event that produced this record.
    public var eventTime: Int64
    /// Milliseconds since epoch, time of the first write for this session. Preserved across updates.
    public var createdAt: Int64
    public var claudePid: Int32?
    /// Seconds since epoch, the Claude process's start time (for stale-pid detection).
    public var claudeStartTime: Int64?

    public init(
        schema: Int,
        sessionId: String,
        cwd: String,
        transcriptPath: String?,
        state: PetState,
        detail: String?,
        lastEvent: String,
        eventTime: Int64,
        createdAt: Int64,
        claudePid: Int32?,
        claudeStartTime: Int64?
    ) {
        self.schema = schema
        self.sessionId = sessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.state = state
        self.detail = detail
        self.lastEvent = lastEvent
        self.eventTime = eventTime
        self.createdAt = createdAt
        self.claudePid = claudePid
        self.claudeStartTime = claudeStartTime
    }
}
