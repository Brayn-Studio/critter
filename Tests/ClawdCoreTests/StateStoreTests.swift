import Foundation
import Testing
@testable import ClawdCore

private func tmpPaths() -> ClawdPaths {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("clawd-tests-\(UUID().uuidString)")
    return ClawdPaths(clawdHome: base.appendingPathComponent(".clawd"), claudeHome: base.appendingPathComponent(".claude"))
}

private func rec(_ sessionId: String, _ state: PetState, t: Int64) -> SessionRecord {
    SessionRecord(
        schema: 1, sessionId: sessionId, cwd: "/x", transcriptPath: nil, state: state, detail: nil,
        lastEvent: "Test", eventTime: t, createdAt: t, claudePid: nil, claudeStartTime: nil
    )
}

@Test func olderEventDoesNotOverwrite() throws {
    let s = StateStore(paths: tmpPaths())
    try s.update(sessionId: "a") { _ in .write(rec("a", .done, t: 20)) }
    try s.update(sessionId: "a") { _ in .write(rec("a", .running, t: 10)) }
    #expect(s.read(sessionId: "a")?.state == .done)
}

@Test func concurrentUpdatesKeepNewestAndValidJSON() throws {
    let s = StateStore(paths: tmpPaths())
    DispatchQueue.concurrentPerform(iterations: 200) { i in
        try? s.update(sessionId: "a") { _ in .write(rec("a", i.isMultiple(of: 2) ? .running : .waiting, t: Int64(i))) }
    }
    #expect(s.read(sessionId: "a")?.eventTime == 199)
}

@Test func corruptFilesAreSkipped() throws {
    let paths = tmpPaths()
    let s = StateStore(paths: paths)
    try s.update(sessionId: "a") { _ in .write(rec("a", .idle, t: 1)) }
    try "{not json".write(to: paths.sessionsDir.appendingPathComponent("b.json"), atomically: true, encoding: .utf8)
    let all = s.readAll()
    #expect(all.count == 1)
    #expect(all.first?.sessionId == "a")
}

@Test func deleteRemovesFile() throws {
    let paths = tmpPaths()
    let s = StateStore(paths: paths)
    try s.update(sessionId: "a") { _ in .write(rec("a", .idle, t: 1)) }
    s.delete(sessionId: "a")
    #expect(s.read(sessionId: "a") == nil)
    #expect(!FileManager.default.fileExists(atPath: paths.stateFile(sessionId: "a")!.path))
}

@Test func invalidSessionIdThrows() {
    let s = StateStore(paths: tmpPaths())
    #expect(throws: (any Error).self) {
        try s.update(sessionId: "../x") { _ in .write(rec("../x", .idle, t: 1)) }
    }
}

@Test func appStatusRoundTrip() throws {
    let paths = tmpPaths()
    let store = AppStatusStore(paths: paths)
    let status = AppStatus(pid: 123, visible: true, heartbeat: 456, version: "1.0")
    try store.write(status)
    #expect(store.read() == status)
}
