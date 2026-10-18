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

    public init(
        sessions: [PetSession], skins: [String: String] = [:], statuses: [StatusLineRecord] = [],
        pending: [PendingRequest] = [], branches: [String: String] = [:],
        estimates: [String: ContextEstimate] = [:], prefs: BridgePrefs, home: String
    ) {
        self.sessions = sessions
        self.skins = skins
        self.statuses = statuses
        self.pending = pending
        self.branches = branches
        self.estimates = estimates
        self.prefs = prefs
        self.home = home
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
            return BridgeSession(
                id: session.id, name: session.name, source: session.source, state: session.state,
                detail: session.detail, activity: session.activity,
                cwd: tilde(session.cwd, home: inputs.home),
                branch: inputs.branches[session.cwd],
                model: status?.modelDisplayName ?? estimate?.model,
                context: context(status: status, estimate: estimate),
                skin: inputs.skins[session.id] ?? inputs.prefs.skin,
                eventTime: session.eventTime, startedAt: session.sortKey, tracked: session.tracked
            )
        }
        let known = Set(inputs.sessions.map(\.id))
        let pending = inputs.pending
            .filter { known.contains($0.sessionId) }
            .sorted { $0.createdAt < $1.createdAt }
            .map {
                BridgePending(
                    requestId: $0.requestId, sessionId: $0.sessionId, kind: $0.kind, toolName: $0.toolName,
                    summary: $0.summary, input: $0.input, createdAt: $0.createdAt, expiresAt: $0.expiresAt
                )
            }
        let limits = inputs.statuses
            .filter { $0.fiveHour != nil || $0.sevenDay != nil }
            .max { $0.updatedAt < $1.updatedAt }
            .map { BridgeLimits(fiveHour: $0.fiveHour, sevenDay: $0.sevenDay, updatedAt: $0.updatedAt) }
        return SnapshotBody(sessions: sessions, limits: limits, pending: pending, prefs: inputs.prefs)
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
}
