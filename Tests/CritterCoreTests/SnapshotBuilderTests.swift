import Foundation
import Testing
@testable import CritterCore

private let prefs = BridgePrefs(skin: "clawd", randomSkins: false, idleDim: 0.5, mergeThreshold: 5, soundTheme: "pixel")

private func session(_ id: String, cwd: String = "/Users/me/proj") -> PetSession {
    PetSession(id: id, name: id, source: .terminal, state: .idle, detail: nil, cwd: cwd, pid: nil,
               transcriptPath: nil, tracked: true, eventTime: 1, sortKey: 2)
}

private func request(_ id: String, session: String, createdAt: Int64) -> PendingRequest {
    PendingRequest(requestId: id, sessionId: session, kind: .permission, toolName: "Bash", summary: "s",
                   input: .null, matchKey: "k", createdAt: createdAt, expiresAt: createdAt + 10, hookPid: 1)
}

@Test func snapshotUsesStatusLineContextOverEstimate() {
    let status = StatusLineRecord(sessionId: "a", updatedAt: 1, modelId: "claude-opus-5-5", modelDisplayName: "Opus",
                                  contextWindowSize: 200_000, contextUsedPercentage: 33.0)
    let body = SnapshotBuilder.build(SnapshotInputs(
        sessions: [session("a")], statuses: [status], estimates: ["a": ContextEstimate(usedTokens: 9, model: "x")],
        prefs: prefs, home: "/Users/me"))
    #expect(body.sessions[0].context == BridgeContext(usedPercent: 33.0, windowSize: 200_000, estimated: false))
    #expect(body.sessions[0].model == "Opus")
}

@Test func snapshotFallsBackToEstimateMarkedEstimated() {
    let body = SnapshotBuilder.build(SnapshotInputs(
        sessions: [session("a")], estimates: ["a": ContextEstimate(usedTokens: 5210, model: "claude-opus-5-5")],
        prefs: prefs, home: "/Users/me"))
    #expect(body.sessions[0].context == BridgeContext(usedPercent: 0.5, windowSize: 1_000_000, estimated: true))
    #expect(body.sessions[0].model == "claude-opus-5-5")
    let none = SnapshotBuilder.build(SnapshotInputs(sessions: [session("a")], prefs: prefs, home: "/"))
    #expect(none.sessions[0].context == nil && none.sessions[0].model == nil)
}

@Test func limitsComeFromNewestRecordThatHasThem() {
    func w(_ p: Double) -> RateWindow { RateWindow(usedPercentage: p, resetsAt: 1) }
    let body = SnapshotBuilder.build(SnapshotInputs(
        sessions: [], statuses: [
            StatusLineRecord(sessionId: "A", updatedAt: 10, fiveHour: w(1)),
            StatusLineRecord(sessionId: "B", updatedAt: 30, fiveHour: w(2), sevenDay: w(3)),
            StatusLineRecord(sessionId: "C", updatedAt: 50),
        ], prefs: prefs, home: "/"))
    #expect(body.limits == BridgeLimits(fiveHour: w(2), sevenDay: w(3), updatedAt: 30))
    #expect(SnapshotBuilder.build(SnapshotInputs(sessions: [], prefs: prefs, home: "/")).limits == nil)
}

@Test func snapshotTildesHomeAndPicksSkin() {
    let body = SnapshotBuilder.build(SnapshotInputs(
        sessions: [session("b", cwd: "/Users/me/proj"), session("a", cwd: "/elsewhere")],
        skins: ["a": "robot"], branches: ["/Users/me/proj": "main"], prefs: prefs, home: "/Users/me"))
    #expect(body.sessions.map(\.id) == ["b", "a"])
    #expect(body.sessions[0].cwd == "~/proj")
    #expect(body.sessions[0].skin == "clawd")
    #expect(body.sessions[0].branch == "main")
    #expect(body.sessions[1].cwd == "/elsewhere")
    #expect(body.sessions[1].skin == "robot")
}

@Test func pendingOfUnknownSessionIsDropped() {
    let body = SnapshotBuilder.build(SnapshotInputs(
        sessions: [session("a")],
        pending: [request("r2", session: "a", createdAt: 20), request("r1", session: "a", createdAt: 10), request("r3", session: "gone", createdAt: 5)],
        prefs: prefs, home: "/"))
    #expect(body.pending.map(\.requestId) == ["r1", "r2"])
}
