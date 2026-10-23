import Foundation
import Testing
@testable import CritterCore

private let prefs = BridgePrefs(skin: "sprig", randomSkins: false, idleDim: 0.5, mergeThreshold: 5, soundTheme: "pixel")

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
    #expect(body.sessions[0].skin == "sprig")
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

@Test func codexPhoneSnapshotUsesLoggedTelemetryAndKeepsProviderLimitsSeparate() {
    var codex = session("codex-a")
    codex.source = .codexDesktop
    codex.telemetry = CodexTelemetry(
        model: "gpt-6-sol", usedTokens: 25_840, contextWindow: 258_400,
        fiveHour: RateWindow(usedPercentage: 31, resetsAt: 100), limitsUpdatedAt: 42
    )
    let body = SnapshotBuilder.build(SnapshotInputs(
        sessions: [codex, session("claude")], statuses: [
            StatusLineRecord(sessionId: "codex-a", updatedAt: 200, modelDisplayName: "Wrong Claude Model",
                             contextWindowSize: 200_000, contextUsedPercentage: 88,
                             fiveHour: RateWindow(usedPercentage: 99, resetsAt: 2)),
            StatusLineRecord(sessionId: "claude", updatedAt: 100,
                             fiveHour: RateWindow(usedPercentage: 11, resetsAt: 3)),
        ], estimates: ["codex-a": ContextEstimate(usedTokens: 900_000, model: "Wrong Estimate")],
        prefs: prefs, home: "/Users/me"
    ))
    #expect(body.sessions[0].model == "gpt-6-sol")
    #expect(body.sessions[0].context == BridgeContext(usedPercent: 10, windowSize: 258_400, estimated: false))
    #expect(body.sessions[0].limits == BridgeLimits(fiveHour: RateWindow(usedPercentage: 31, resetsAt: 100), updatedAt: 42))
    #expect(body.sessions[1].limits == nil)
    #expect(body.limits == BridgeLimits(fiveHour: RateWindow(usedPercentage: 11, resetsAt: 3), updatedAt: 100))
}

@Test func codexPhoneSnapshotNeverInventsAWindowAndDefaultsToReadOnly() {
    var codex = session("codex-a")
    codex.source = .codexTerminal
    codex.telemetry = CodexTelemetry(model: "gpt-6-astra", usedTokens: 12_000)
    let body = SnapshotBuilder.build(SnapshotInputs(sessions: [codex, session("claude")], prefs: prefs, home: "/"))
    #expect(body.sessions[0].model == "gpt-6-astra")
    #expect(body.sessions[0].context == nil)
    #expect(body.sessions[0].capabilities == BridgeCapabilities(readOnlyReason: "尚未连接 Codex 控制通道"))
    #expect(body.sessions[1].capabilities == nil)
    #expect(body.limits == nil)
}

@Test func codexPhoneSnapshotUsesReportedControlCapabilities() {
    var codex = session("codex-a")
    codex.source = .codexDesktop
    let capabilities = BridgeCapabilities(canSay: true, canAnswer: false, canInterrupt: true)
    let body = SnapshotBuilder.build(SnapshotInputs(
        sessions: [codex], prefs: prefs, home: "/", capabilities: ["codex-a": capabilities]
    ))
    #expect(body.sessions[0].capabilities == capabilities)
}

@Test func codexUnboundedPendingDoesNotBecomeAMaxLongPhoneTimeout() {
    var prompt = request("codex-request",session:"codex-session",createdAt:10)
    prompt.expiresAt = .max
    let body = SnapshotBuilder.build(SnapshotInputs(sessions:[session("codex-session")],pending:[prompt],prefs:prefs,home:"/"))
    #expect(body.pending.first?.expiresAt == nil)
}
