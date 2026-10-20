import Foundation
import Testing
@testable import CritterCore

private func rec(
    _ id: String,
    cwd: String = "/x",
    state: PetState = .running,
    detail: String? = nil,
    eventTime: Int64 = 0,
    createdAt: Int64 = 0,
    claudePid: Int32? = nil,
    entrypoint: String? = nil,
    activity: String? = nil
) -> SessionRecord {
    SessionRecord(
        schema: 1, sessionId: id, cwd: cwd, transcriptPath: nil, state: state, detail: detail,
        lastEvent: "Test", eventTime: eventTime, createdAt: createdAt, claudePid: claudePid, claudeStartTime: nil,
        entrypoint: entrypoint, activity: activity
    )
}

private func entry(
    _ id: String,
    cwd: String = "/x",
    pid: Int32 = 1,
    startedAt: Int64? = nil,
    entrypoint: String? = "cli",
    name: String? = nil
) -> RegistryEntry {
    RegistryEntry(pid: pid, sessionId: id, cwd: cwd, startedAt: startedAt, entrypoint: entrypoint, kind: "interactive", name: name)
}

@Test func untrackedRegistrySessionShownIdleWithHint() {
    let registry = [entry("a", cwd: "/Users/u/robocup-81", entrypoint: "claude-vscode", name: "robocup-81")]
    let result = SessionCatalog.build(records: [], registry: registry, dismissed: [:])
    #expect(result.count == 1)
    let s = result[0]
    #expect(s.state == .idle)
    #expect(!s.tracked)
    #expect(s.detail == SessionCatalog.untrackedHint)
    #expect(s.source == .vscode)
    #expect(s.name == "robocup-81")
    #expect(s.eventTime == 0)
}

@Test func sdkSessionsExcluded() {
    let registry = [entry("a", entrypoint: "sdk-cli")]
    let records = [rec("a")]
    let result = SessionCatalog.build(records: records, registry: registry, dismissed: [:])
    #expect(result.isEmpty)
}

/// F5: `claude -p` / SDK runs may not be (or not yet be) in the registry; their state file's
/// own entrypoint must keep them off the pet -- no flash, no sound, no reset of the user's
/// expand/collapse choice.
@Test func sdkSessionsExcludedByTheirStateFileToo() {
    #expect(SessionCatalog.build(records: [rec("a", entrypoint: "sdk-cli")], registry: [], dismissed: [:]).isEmpty)
    #expect(SessionCatalog.build(records: [rec("a", entrypoint: "sdk-ts")], registry: [], dismissed: [:]).isEmpty)
    // Either source saying SDK is enough.
    #expect(SessionCatalog.build(records: [rec("a", entrypoint: "sdk-cli")], registry: [entry("a", entrypoint: "cli")], dismissed: [:]).isEmpty)
    #expect(SessionCatalog.build(records: [rec("a", entrypoint: "cli")], registry: [entry("a", entrypoint: "sdk-cli")], dismissed: [:]).isEmpty)
}

@Test func sourceLabelFallsBackToTheStateFilesEntrypoint() {
    let unregistered = SessionCatalog.build(records: [rec("a", entrypoint: "claude-vscode")], registry: [], dismissed: [:])
    #expect(unregistered.map(\.source) == [.vscode])
    // The registry still wins when it has the session.
    let registered = SessionCatalog.build(records: [rec("a", entrypoint: "claude-vscode")], registry: [entry("a", entrypoint: "cli")], dismissed: [:])
    #expect(registered.map(\.source) == [.terminal])
    // Neither knows: "其他", and the session is shown.
    #expect(SessionCatalog.build(records: [rec("a")], registry: [], dismissed: [:]).map(\.source) == [.other])
}

@Test func onlyRecordNoRegistryShownNormally() {
    let records = [rec("a", state: .waiting, detail: "需要你确认：Bash(ls)", eventTime: 10)]
    let result = SessionCatalog.build(records: records, registry: [], dismissed: [:])
    #expect(result.count == 1)
    #expect(result[0].tracked)
    #expect(result[0].state == .waiting)
    #expect(result[0].detail == "需要你确认：Bash(ls)")
}

@Test func dismissedHiddenUntilNewEvent() {
    let records = [rec("a", eventTime: 50)]
    #expect(SessionCatalog.build(records: records, registry: [], dismissed: ["a": 50]).isEmpty)
    let records2 = [rec("a", eventTime: 51)]
    #expect(SessionCatalog.build(records: records2, registry: [], dismissed: ["a": 50]).count == 1)
}

@Test func duplicateNamesGetSourceSuffix() {
    let registry = [
        entry("a", entrypoint: "cli", name: "api"),
        entry("b", entrypoint: "claude-vscode", name: "api"),
    ]
    let records = [rec("a"), rec("b")]
    let result = SessionCatalog.build(records: records, registry: registry, dismissed: [:])
    let names = Set(result.map(\.name))
    #expect(names == ["api（终端）", "api（VS Code）"])
}

@Test func uniqueNamesAreNotSuffixed() {
    let registry = [entry("a", entrypoint: "cli", name: "api")]
    let records = [rec("a")]
    let result = SessionCatalog.build(records: records, registry: registry, dismissed: [:])
    #expect(result.first?.name == "api")
}

@Test func nameFallsBackToLastCwdSegment() {
    let records = [rec("a", cwd: "/Users/u/CODESPACE/critter")]
    let result = SessionCatalog.build(records: records, registry: [], dismissed: [:])
    #expect(result.first?.name == "critter")
}

@Test func sortedByStartTimeThenId() {
    let registry = [
        entry("b", startedAt: 5),
        entry("a", startedAt: 5),
        entry("c", startedAt: 1),
    ]
    let result = SessionCatalog.build(records: [], registry: registry, dismissed: [:])
    #expect(result.map(\.id) == ["c", "a", "b"])
}

@Test func pidPrefersRegistryOverRecord() {
    let registry = [entry("a", pid: 10)]
    let records = [rec("a", claudePid: 20)]
    let result = SessionCatalog.build(records: records, registry: registry, dismissed: [:])
    #expect(result.first?.pid == 10)

    let recordOnly = SessionCatalog.build(records: [rec("b", claudePid: 30)], registry: [], dismissed: [:])
    #expect(recordOnly.first?.pid == 30)
}

@Test func duplicateRegistryEntriesDoNotCrashAndTheNewestWins() {
    // The same conversation resumed in two terminals: two live processes, one session id.
    let registry = [
        entry("a", cwd: "/x/old", pid: 11, startedAt: 100, name: "older"),
        entry("a", cwd: "/x/new", pid: 22, startedAt: 200, name: "newer"),
        entry("b", pid: 33, startedAt: 50, name: "solo"),
    ]
    let result = SessionCatalog.build(records: [], registry: registry, dismissed: [:])
    #expect(result.map(\.id) == ["b", "a"])
    #expect(result[1].name == "newer")
    #expect(result[1].pid == 22)
}

@Test func duplicateRecordsDoNotCrashAndTheNewestWins() {
    // A stray copy of a state file (e.g. `a copy.json`) carrying the same session id.
    let records = [
        rec("a", state: .done, detail: "newer", eventTime: 20),
        rec("a", state: .running, detail: "older", eventTime: 10),
    ]
    let result = SessionCatalog.build(records: records, registry: [], dismissed: [:])
    #expect(result.count == 1)
    #expect(result[0].state == .done)
    #expect(result[0].detail == "newer")
}

@Test func catalogCarriesActivity() {
    let tracked = SessionCatalog.build(records: [rec("a", activity: "bash")], registry: [], dismissed: [:])
    #expect(tracked.first?.activity == "bash")
    let untracked = SessionCatalog.build(records: [], registry: [entry("b")], dismissed: [:])
    #expect(untracked.first?.activity == nil)
}

@Test func catalogRecognizesLegacyCodexWithoutAClientGuess() {
    let id = "11111111-2222-4333-8444-555555555555"
    var legacy = rec(id)
    legacy.transcriptPath = "/Users/u/.codex/sessions/2026/10/20/rollout-2026-10-20T10-00-00-\(id).jsonl"
    let result = SessionCatalog.build(records: [legacy], registry: [entry(id, entrypoint: "cli")], dismissed: [:])
    #expect(result.first?.source.rawValue == "codex")
    #expect(result.first?.source.label == "Codex")

    var claude = legacy
    claude.transcriptPath = "/Users/u/.claude/projects/x/\(id).jsonl"
    #expect(SessionCatalog.build(records: [claude], registry: [entry(id)], dismissed: [:]).first?.source == .terminal)
    claude.transcriptPath = "/Users/u/.codex/sessions/rollout-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.jsonl"
    #expect(SessionCatalog.build(records: [claude], registry: [], dismissed: [:]).first?.source == .other)
}

@Test func catalogKeepsPositiveCodexIdentityAndLegacyDismissal() {
    let rawID = "11111111-2222-4333-8444-555555555555"
    let id = "codex-" + rawID
    let record = rec(id, eventTime: 50, claudePid: 42, entrypoint: "codex-desktop")
    let identified = SessionCatalog.build(records: [record], registry: [entry(id, name: "unrelated Claude")], dismissed: [:])
    #expect(identified.first?.source == .codexDesktop)
    #expect(identified.first?.pid == 42)
    #expect(identified.first?.name == "x")
    #expect(SessionCatalog.build(records: [record], registry: [entry(id, entrypoint: "sdk-cli")], dismissed: [:]).count == 1)
    #expect(SessionCatalog.build(records: [record], registry: [], dismissed: [rawID: 50]).isEmpty)
    var newer = record
    newer.eventTime = 51
    #expect(SessionCatalog.build(records: [newer], registry: [], dismissed: [rawID: 50]).count == 1)
    #expect(SessionCatalog.build(records: [rec(id)], registry: [], dismissed: [:]).first?.source.rawValue == "codex")
    #expect(SessionCatalog.build(records: [rec("codex-invalid")], registry: [], dismissed: [:]).first?.source == .other)
}

@Test func catalogCarriesCodexTelemetryToTheVisibleSession() {
    var record = rec("codex-11111111-2222-4333-8444-555555555555")
    record.telemetry = CodexTelemetry(model: "gpt-6-sol", usedTokens: 25, contextWindow: 100)
    let result = SessionCatalog.build(records: [record], registry: [], dismissed: [:])
    #expect(result.first?.telemetry?.model == "gpt-6-sol")
    #expect(result.first?.telemetry?.usedTokens == 25)
    #expect(result.first?.telemetry?.contextWindow == 100)
}

@Test func catalogCanonicalCodexOwnsPresentationWhenLegacyHookRecordReturns() {
    let rawID = "11111111-2222-4333-8444-555555555555"
    let transcript = "/Users/u/.codex/sessions/2026/10/20/rollout-2026-10-20T10-00-00-\(rawID).jsonl"
    var legacy = rec(rawID, cwd: "/work/legacy", state: .waiting, detail: "请求输入", eventTime: 200, claudePid: 99, activity: "read")
    legacy.transcriptPath = transcript
    var canonical = rec("codex-" + rawID, cwd: "/work/current", state: .running, detail: "命令：swift test", eventTime: 100,
                        claudePid: 42, entrypoint: "codex-desktop", activity: "bash")
    canonical.transcriptPath = transcript

    for records in [[legacy, canonical], [canonical, legacy]] {
        let result = SessionCatalog.build(records: records, registry: [], dismissed: [:])
        #expect(result.count == 1)
        #expect(result.first?.id == "codex-" + rawID)
        #expect(result.first?.name == "current")
        #expect(result.first?.source == .codexDesktop)
        #expect(result.first?.pid == 42)
        #expect(result.first?.state == .running)
        #expect(result.first?.activity == "bash")
        #expect(result.first?.detail == "命令：swift test")
        #expect(result.first?.eventTime == 100)
        #expect(SessionCatalog.build(records: records, registry: [], dismissed: [rawID: 100]).isEmpty)
    }

    let legacyOnly = SessionCatalog.build(records: [legacy], registry: [], dismissed: [:])
    #expect(legacyOnly.count == 1)
    #expect(legacyOnly.first?.id == rawID)
    #expect(legacyOnly.first?.source == .codex)
    #expect(legacyOnly.first?.state == .waiting)
}

@Test func catalogCodexDedupDoesNotHideAnUnconfirmedClaudeUUID() {
    let rawID = "11111111-2222-4333-8444-555555555555"
    var claude = rec(rawID, state: .waiting, entrypoint: "cli")
    claude.transcriptPath = "/Users/u/.claude/projects/x/\(rawID).jsonl"
    let canonical = rec("codex-" + rawID, entrypoint: "codex-desktop")
    let result = SessionCatalog.build(records: [claude, canonical], registry: [], dismissed: [:])
    #expect(Set(result.map(\.id)) == [rawID, "codex-" + rawID])
    #expect(result.first { $0.id == rawID }?.source == .terminal)
    #expect(result.first { $0.id == rawID }?.state == .waiting)

    let registryOnly = SessionCatalog.build(records: [canonical], registry: [entry(rawID)], dismissed: [:])
    #expect(Set(registryOnly.map(\.id)) == [rawID, "codex-" + rawID])
    let malformed = SessionCatalog.build(records: [rec("not-a-uuid", entrypoint: "codex"), rec("codex-not-a-uuid", entrypoint: "codex")], registry: [], dismissed: [:])
    #expect(malformed.count == 2)
}
