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
    claudePid: Int32? = nil
) -> SessionRecord {
    SessionRecord(
        schema: 1, sessionId: id, cwd: cwd, transcriptPath: nil, state: state, detail: detail,
        lastEvent: "Test", eventTime: eventTime, createdAt: createdAt, claudePid: claudePid, claudeStartTime: nil
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
