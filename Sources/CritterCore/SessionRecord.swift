import Foundation

/// On-disk representation of a single session's pet state (`~/.critter/sessions/<id>.json`).
/// Schema version 1. Fields added later are optional, so older files still decode.
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
    /// Owning agent process. The persisted field name is kept for schema-1 compatibility;
    /// Codex records use the same lifecycle/reaper machinery as Claude records.
    public var claudePid: Int32?
    /// Seconds since epoch, the owning process's start time (for stale-pid detection).
    public var claudeStartTime: Int64?
    /// How the session was started (`cli`, `claude-vscode`, `sdk-cli`, …): from Claude's
    /// registry entry, else `CLAUDE_CODE_ENTRYPOINT` in the hook's environment. Lets SDK /
    /// `claude -p` sessions be excluded even when the registry doesn't list them.
    public var entrypoint: String?
    /// The `WorkActivity` raw value while the session is running a tool or thinking; nil
    /// otherwise (and in files written before this field existed).
    public var activity: String?
    /// Codex's latest rollout-reported model, context and account usage; absent in older files.
    public var telemetry: CodexTelemetry?
    /// Latest public assistant commentary for the active turn; never internal reasoning.
    public var progress: String?

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
        claudeStartTime: Int64?,
        entrypoint: String? = nil,
        activity: String? = nil,
        telemetry: CodexTelemetry? = nil,
        progress: String? = nil
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
        self.entrypoint = entrypoint
        self.activity = activity
        self.telemetry = telemetry
        self.progress = progress
    }
}
