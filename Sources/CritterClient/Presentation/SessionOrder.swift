import CritterKit

public enum SessionOrder {
    /// Sessions with an open request first, the one waiting longest first; the rest keep the Mac's order.
    public static func forBoard(_ body: SnapshotBody) -> [BridgeSession] {
        var oldestRequest: [String: Int64] = [:]
        for request in body.pending {
            oldestRequest[request.sessionId] = min(oldestRequest[request.sessionId] ?? request.createdAt, request.createdAt)
        }
        var waiting: [(since: Int64, index: Int, session: BridgeSession)] = []
        var others: [BridgeSession] = []
        for (index, session) in body.sessions.enumerated() {
            if let since = oldestRequest[session.id] {
                waiting.append((since, index, session))
            } else {
                others.append(session)
            }
        }
        // Sessions waiting since the same moment stay in the Mac's order.
        waiting.sort { ($0.since, $0.index) < ($1.since, $1.index) }
        return waiting.map(\.session) + others
    }
}
