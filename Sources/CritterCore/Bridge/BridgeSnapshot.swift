import Foundation

/// Everything `SnapshotBuilder` needs; the caller owns reading the files.
public struct SnapshotInputs: Sendable {
    public var sessions: [PetSession]
    /// Session id -> skin id.
    public var skins: [String: String]
    public var statuses: [StatusLineRecord]
    public var pending: [PendingRequest]
    /// cwd -> git branch.
    public var branches: [String: String]
    /// Session id -> transcript-based context estimate.
    public var estimates: [String: ContextEstimate]
    public var prefs: BridgePrefs
    public var home: String
    /// Session id -> capabilities reported by the live provider control channel.
    public var capabilities: [String: BridgeCapabilities]

    public init(
        sessions: [PetSession], skins: [String: String] = [:], statuses: [StatusLineRecord] = [],
        pending: [PendingRequest] = [], branches: [String: String] = [:],
        estimates: [String: ContextEstimate] = [:], prefs: BridgePrefs, home: String,
        capabilities: [String: BridgeCapabilities] = [:]
    ) {
        self.sessions = sessions
        self.skins = skins
        self.statuses = statuses
        self.pending = pending
        self.branches = branches
        self.estimates = estimates
        self.prefs = prefs
        self.home = home
        self.capabilities = capabilities
    }
}

/// Turns the Mac's session state into the `snapshot` message body. Pure.
public enum SnapshotBuilder {
    public static func build(_ inputs: SnapshotInputs) -> SnapshotBody {
        // Newest status record per session.
        let statusById = Dictionary(inputs.statuses.map { ($0.sessionId, $0) }) { a, b in
            b.updatedAt > a.updatedAt ? b : a
        }
        let sessions = inputs.sessions.map { session -> BridgeSession in
            let status = statusById[session.id]
            let estimate = inputs.estimates[session.id]
            let codex = session.source.isCodex
            return BridgeSession(
                id: session.id, name: session.name, source: session.source, state: session.state,
                detail: session.detail, activity: session.activity,
                cwd: tilde(session.cwd, home: inputs.home),
                branch: inputs.branches[session.cwd],
                model: codex ? session.telemetry?.model : status?.modelDisplayName ?? estimate?.model,
                context: codex ? context(telemetry: session.telemetry) : context(status: status, estimate: estimate),
                skin: inputs.skins[session.id] ?? inputs.prefs.skin,
                eventTime: session.eventTime, startedAt: session.sortKey, tracked: session.tracked,
                limits: codex ? limits(telemetry: session.telemetry, eventTime: session.eventTime) : nil,
                capabilities: inputs.capabilities[session.id] ?? defaultCapabilities(for: session.source)
            )
        }
        let known = Set(inputs.sessions.map(\.id))
        let pending = inputs.pending
            .filter { known.contains($0.sessionId) }
            .sorted { $0.createdAt < $1.createdAt }
            .map {
                BridgePending(
                    requestId: $0.requestId, sessionId: $0.sessionId, kind: $0.kind, toolName: $0.toolName,
                    summary: $0.summary, input: $0.input, createdAt: $0.createdAt,
                    expiresAt: $0.expiresAt == .max ? nil : $0.expiresAt
                )
            }
        let codexIDs = Set(inputs.sessions.filter { $0.source.isCodex }.map(\.id))
        let limits = inputs.statuses
            .filter { !codexIDs.contains($0.sessionId) && ($0.fiveHour != nil || $0.sevenDay != nil) }
            .max { $0.updatedAt < $1.updatedAt }
            .map { BridgeLimits(fiveHour: $0.fiveHour, sevenDay: $0.sevenDay, updatedAt: $0.updatedAt) }
        return SnapshotBody(sessions: sessions, limits: limits, pending: pending, prefs: inputs.prefs)
    }

    /// What a phone may do with a session before its control channel has reported. Claude sessions
    /// leave it nil (the bridge answers and says through hooks); the others start read-only.
    private static func defaultCapabilities(for source: SessionSource) -> BridgeCapabilities? {
        if source.isCodex { return BridgeCapabilities(readOnlyReason: "尚未连接 Codex 控制通道") }
        if source.isKimi { return BridgeCapabilities(readOnlyReason: "尚未连接 Kimi Code") }
        // DeepSeek's hooks can carry an answer back, but there is no way to type into the session.
        if source.isDeepSeek {
            return BridgeCapabilities(canSay: false, canAnswer: true, canInterrupt: false, readOnlyReason: "DeepSeek Harness 会话暂不支持从手机发消息")
        }
        return nil
    }

    private static func tilde(_ cwd: String, home: String) -> String {
        guard !home.isEmpty else { return cwd }
        if cwd == home { return "~" }
        return cwd.hasPrefix(home + "/") ? "~" + cwd.dropFirst(home.count) : cwd
    }

    private static func context(status: StatusLineRecord?, estimate: ContextEstimate?) -> BridgeContext? {
        let modelId = status?.modelId ?? estimate?.model
        if let status, let percent = status.contextUsedPercentage {
            return BridgeContext(
                usedPercent: percent,
                windowSize: status.contextWindowSize ?? ContextUsage.windowSize(forModel: modelId),
                estimated: false
            )
        }
        if let estimate {
            let window = status?.contextWindowSize ?? ContextUsage.windowSize(forModel: modelId)
            return BridgeContext(
                usedPercent: ContextUsage.percent(usedTokens: estimate.usedTokens, windowSize: window),
                windowSize: window, estimated: true
            )
        }
        return nil
    }

    private static func context(telemetry: CodexTelemetry?) -> BridgeContext? {
        guard let used = telemetry?.usedTokens, used >= 0,
              let window = telemetry?.contextWindow, window > 0 else { return nil }
        return BridgeContext(
            usedPercent: ContextUsage.percent(usedTokens: used, windowSize: window),
            windowSize: window, estimated: false
        )
    }

    private static func limits(telemetry: CodexTelemetry?, eventTime: Int64) -> BridgeLimits? {
        guard let telemetry, telemetry.fiveHour != nil || telemetry.sevenDay != nil else { return nil }
        return BridgeLimits(
            fiveHour: telemetry.fiveHour, sevenDay: telemetry.sevenDay,
            updatedAt: telemetry.limitsUpdatedAt ?? eventTime
        )
    }
}
