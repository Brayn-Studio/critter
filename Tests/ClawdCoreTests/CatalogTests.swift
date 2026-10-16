import Foundation
import Testing
@testable import ClawdCore

private func rec(
    _ id: String,
    cwd: String = "/x",
    state: PetState = .running,
    detail: String? = nil,
    eventTime: Int64 = 0,
    createdAt: Int64 = 0,
    claudePid: Int32? = nil,
    entrypoint: String? = nil
) -> SessionRecord {
    SessionRecord(
        schema: 1, sessionId: id, cwd: cwd, transcriptPath: nil, state: state, detail: detail,
        lastEvent: "Test", eventTime: eventTime, createdAt: createdAt, claudePid: claudePid, claudeStartTime: nil,
        entrypoint: entrypoint
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
    let records = [rec("a", cwd: "/Users/u/CODESPACE/clawd")]
    let result = SessionCatalog.build(records: records, registry: [], dismissed: [:])
    #expect(result.first?.name == "clawd")
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
