import Foundation
import Testing
@testable import CritterCore

private func rec(_ id: String, pid: Int32?, start: Int64? = nil, t: Int64 = 0) -> SessionRecord {
    SessionRecord(
        schema: 1, sessionId: id, cwd: "/x", transcriptPath: nil, state: .running, detail: nil,
        lastEvent: "Test", eventTime: t, createdAt: t, claudePid: pid, claudeStartTime: start
    )
}

@Test func cleanupRules() {
    let alive: (Int32) -> Bool = { $0 == 10 || $0 == 11 }
    let start: (Int32) -> Int64? = { $0 == 10 ? 100 : 500 }
    let recs = [rec("a", pid: 10, start: 100), rec("b", pid: 11, start: 100), rec("c", pid: 12, start: 1),
                rec("d", pid: nil, t: 0), rec("e", pid: 11, start: nil)]
    #expect(Set(StartupCleanup.deadSessionIds(records: recs, isAlive: alive, startTime: start, now: 90_000_000)) == ["b", "c", "d"])
}

@Test func cleanupToleratesSmallStartTimeSkewAndRecentPidlessRecords() {
    let alive: (Int32) -> Bool = { _ in true }
    let start: (Int32) -> Int64? = { _ in 102 }
    let now: Int64 = 90_000_000
    let recs = [
        rec("skew2", pid: 10, start: 100),          // |102 - 100| == 2 s: not "> 2 s"
        rec("skew3", pid: 10, start: 99),           // 3 s apart: reused pid
        rec("fresh", pid: nil, t: now - 1000),       // pid-less but recent
    ]
    #expect(StartupCleanup.deadSessionIds(records: recs, isAlive: alive, startTime: start, now: now) == ["skew3"])
}

@Test func registryEntryDeadWhenProcessGoneOrPidReused() {
    func entry(pid: Int32, startedAt: Int64?) -> RegistryEntry {
        RegistryEntry(pid: pid, sessionId: "s", cwd: "/x", startedAt: startedAt, entrypoint: "cli", kind: nil, name: nil)
    }
    let alive: (Int32) -> Bool = { $0 != 99 }
    // Process started at 100 s; the session started (ms) shortly after it.
    let start: (Int32) -> Int64? = { $0 == 20 ? 500 : 100 }
    #expect(!StartupCleanup.isDead(entry: entry(pid: 10, startedAt: 105_000), isAlive: alive, startTime: start))
    #expect(StartupCleanup.isDead(entry: entry(pid: 99, startedAt: 105_000), isAlive: alive, startTime: start))
    // The pid now belongs to a process that started *after* the session did: reused.
    #expect(StartupCleanup.isDead(entry: entry(pid: 20, startedAt: 105_000), isAlive: alive, startTime: start))
    #expect(!StartupCleanup.isDead(entry: entry(pid: 20, startedAt: nil), isAlive: alive, startTime: start))
}
