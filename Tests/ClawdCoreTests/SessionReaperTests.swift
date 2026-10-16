import Foundation
import Testing
@testable import ClawdCore

private func rec(_ id: String, pid: Int32?, start: Int64? = nil, t: Int64 = 1_000) -> SessionRecord {
    SessionRecord(
        schema: 1, sessionId: id, cwd: "/x", transcriptPath: nil, state: .running, detail: nil,
        lastEvent: "Test", eventTime: t, createdAt: t, claudePid: pid, claudeStartTime: start
    )
}

private func reg(_ pid: Int32, _ sessionId: String, startedAt: Int64? = 500, updatedAt: Int64? = nil) -> RegistryEntry {
    RegistryEntry(pid: pid, sessionId: sessionId, cwd: "/x", startedAt: startedAt, entrypoint: "cli", kind: "interactive", name: nil, updatedAt: updatedAt)
}

private func alive(_ pid: Int32) -> Bool { pid >= 13 }
private func start(_ pid: Int32) -> Int64? { pid == 11 ? 999 : 100 }

/// F2: a rebuild drops records whose Claude is gone or whose pid was reused -- but leaves a
/// pid already watched for exit to the exit watcher.
@Test func reaperDropsRecordsWhoseClaudeIsGoneOrReused() {
    let records = [
        rec("gone", pid: 10, start: 100),
        rec("reused", pid: 11, start: 100),        // pid 11 is alive but started at 999
        rec("watched", pid: 12, start: 100),       // dead, but the exit watcher has it
        rec("live", pid: 13, start: 100),
        rec("pidless", pid: nil),
    ]
    let removals = SessionReaper.staleRecords(
        records: records, liveRegistry: [reg(13, "live")], watchedPids: [12], isAlive: { $0 == 11 || $0 == 13 }, startTime: start
    )
    #expect(removals == [
        .init(sessionId: "gone", pid: 10, eventTime: nil, reason: .exited),
        .init(sessionId: "reused", pid: 11, eventTime: nil, reason: .exited),
    ])
}

/// F13: in-session `/resume` switches a live Claude to another session without SessionEnd.
/// Its registry entry now names the new session, so the old record is a ghost.
@Test func reaperDropsRecordsWhoseClaudeMovedToAnotherSession() {
    let records = [
        rec("old", pid: 14, t: 1_000),
        rec("new", pid: 14, t: 2_000),
        rec("watchedOld", pid: 15, t: 1_000),
    ]
    let registry = [reg(14, "new", updatedAt: 2_500), reg(15, "elsewhere", updatedAt: 3_000)]
    let removals = SessionReaper.staleRecords(records: records, liveRegistry: registry, watchedPids: [15], isAlive: alive, startTime: start)
    #expect(removals == [
        .init(sessionId: "old", pid: 14, eventTime: 1_000, reason: .switched),
        .init(sessionId: "watchedOld", pid: 15, eventTime: 1_000, reason: .switched),
    ])
}

@Test func reaperKeepsRecordsTheRegistryCannotContradict() {
    let records = [
        rec("unregistered", pid: 16),
        rec("shared", pid: 17),       // the same conversation open in two processes
        rec("justCleared", pid: 18, t: 5_000),
        rec("pidless", pid: nil),
    ]
    let registry = [
        reg(17, "shared"), reg(19, "shared"),
        // Written before the record's latest event (e.g. right after `/clear` started a new
        // session): the registry hasn't caught up yet, so it proves nothing.
        reg(18, "beforeClear", updatedAt: 4_000),
    ]
    let removals = SessionReaper.staleRecords(records: records, liveRegistry: registry, watchedPids: [], isAlive: alive, startTime: start)
    #expect(removals.isEmpty)
}

/// An entry that has never been updated was written when its process started.
@Test func reaperFallsBackToStartedAtWhenTheEntryHasNoUpdatedAt() {
    let registry = [reg(20, "current", startedAt: 1_500, updatedAt: nil)]
    let older = SessionReaper.staleRecords(records: [rec("older", pid: 20, t: 1_000)], liveRegistry: registry, watchedPids: [], isAlive: alive, startTime: start)
    #expect(older.map(\.sessionId) == ["older"])
    let newer = SessionReaper.staleRecords(records: [rec("newer", pid: 20, t: 2_000)], liveRegistry: registry, watchedPids: [], isAlive: alive, startTime: start)
    #expect(newer.isEmpty)
}

/// Exit attribution: a record goes with the process named by its pid; a pid-less record goes
/// with the exited process's registry entry -- unless another live process has that session.
@Test func reaperAttributesRecordsToAnExitedProcess() {
    let records = [
        rec("byPid", pid: 30),
        rec("byRegistry", pid: nil),
        rec("alsoElsewhere", pid: nil),
        rec("otherProcess", pid: 31),
        rec("unrelatedPidless", pid: nil),
    ]
    let registry = [reg(30, "byRegistry"), reg(30, "alsoElsewhere"), reg(32, "alsoElsewhere"), reg(31, "otherProcess")]
    let live = [reg(32, "alsoElsewhere"), reg(31, "otherProcess")]
    let removals = SessionReaper.recordsOwned(byExited: 30, records: records, registry: registry, liveRegistry: live)
    #expect(removals == [
        .init(sessionId: "byPid", pid: 30, eventTime: nil, reason: .exited),
        .init(sessionId: "byRegistry", pid: nil, eventTime: nil, reason: .exited),
    ])
}

@Test func reaperLaunchSweepMatchesStartupCleanup() {
    let now: Int64 = 90_000_000
    let records = [rec("gone", pid: 10, start: 100), rec("live", pid: 13, start: 100), rec("ancient", pid: nil, t: 0), rec("recent", pid: nil, t: now - 1)]
    let removals = SessionReaper.launchSweep(records: records, isAlive: alive, startTime: start, now: now)
    #expect(removals == [
        .init(sessionId: "gone", pid: 10, eventTime: nil, reason: .exited),
        .init(sessionId: "ancient", pid: nil, eventTime: 0, reason: .exited),
    ])
}

/// Removals are decided from an unlocked read; under the session lock they only go ahead
/// if the record is still the one that was judged.
@Test func reaperConfirmsUnderTheLock() {
    let byPid = SessionReaper.Removal(sessionId: "s", pid: 10, eventTime: nil, reason: .exited)
    #expect(SessionReaper.confirm(byPid, current: rec("s", pid: 10)) == .delete)
    #expect(SessionReaper.confirm(byPid, current: nil) == .ignore)
    #expect(SessionReaper.confirm(byPid, current: rec("s", pid: 20)) == .ignore) // resumed elsewhere meanwhile
    #expect(SessionReaper.confirm(byPid, current: rec("s", pid: nil)) == .ignore)

    let pidless = SessionReaper.Removal(sessionId: "s", pid: nil, eventTime: nil, reason: .exited)
    #expect(SessionReaper.confirm(pidless, current: rec("s", pid: nil)) == .delete)
    #expect(SessionReaper.confirm(pidless, current: rec("s", pid: 7)) == .ignore)

    let switched = SessionReaper.Removal(sessionId: "s", pid: 14, eventTime: 1_000, reason: .switched)
    #expect(SessionReaper.confirm(switched, current: rec("s", pid: 14, t: 1_000)) == .delete)
    #expect(SessionReaper.confirm(switched, current: rec("s", pid: 14, t: 1_001)) == .ignore) // a new event since
}

/// End to end through the store: a removal judged against a dead process must not delete
/// the record a resumed session's hook has rewritten in the meantime (the flapping in F2).
@Test func reaperRemovalSparesARecordRewrittenByANewProcess() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("clawd-reaper-\(UUID().uuidString)")
    let store = StateStore(paths: ClawdPaths(clawdHome: base.appendingPathComponent(".clawd"), claudeHome: base.appendingPathComponent(".claude")))
    try store.update(sessionId: "s") { _ in .write(rec("s", pid: 10, t: 1_000)) }
    let removal = SessionReaper.staleRecords(records: store.readAll(), liveRegistry: [], watchedPids: [], isAlive: { _ in false }, startTime: { _ in nil })
    #expect(removal.count == 1)

    // `claude --resume s` in a new process: its hook rewrites the record first.
    try store.update(sessionId: "s") { _ in .write(rec("s", pid: 20, t: 2_000)) }
    for r in removal {
        try store.update(sessionId: r.sessionId) { SessionReaper.confirm(r, current: $0) }
    }
    #expect(store.read(sessionId: "s")?.claudePid == 20)
}
