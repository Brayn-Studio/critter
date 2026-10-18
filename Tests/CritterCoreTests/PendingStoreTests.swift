import Foundation
import Testing
@testable import CritterCore

private func tmpPaths() -> CritterPaths {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("critter-pending-tests-\(UUID().uuidString)")
    return CritterPaths(critterHome: base.appendingPathComponent(".critter"), claudeHome: base.appendingPathComponent(".claude"))
}

private func request(
    _ id: String, session: String = "s1", tool: String = "Bash", key: String = "k",
    expires: Int64 = 10_000, pid: Int32 = 100
) -> PendingRequest {
    PendingRequest(
        requestId: id, sessionId: session, kind: .permission, toolName: tool, summary: "需要你确认：\(tool)()",
        input: .object(["command": .string("ls")]), matchKey: key, createdAt: 1000, expiresAt: expires, hookPid: pid
    )
}

private func permissions(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
}

@Test func storeRoundTripAndPermissions() throws {
    let paths = tmpPaths()
    let store = PendingStore(paths: paths)
    try store.write(request("r1"))
    #expect(store.read(requestId: "r1") == request("r1"))
    #expect(store.readAll() == [request("r1")])
    #expect(permissions(paths.pendingDir.appendingPathComponent("r1.json")) == 0o600)
    #expect(permissions(paths.pendingDir) == 0o700)

    try store.writeAnswer(AnswerPayload(decision: "allow"), requestId: "r1")
    #expect(store.readAnswer(requestId: "r1") == AnswerPayload(decision: "allow"))
    #expect(permissions(paths.answersDir.appendingPathComponent("r1.json")) == 0o600)
    #expect(permissions(paths.answersDir) == 0o700)

    store.remove(requestId: "r1")
    #expect(store.read(requestId: "r1") == nil)
    #expect(store.readAnswer(requestId: "r1") == nil)
}

@Test func storeRejectsBadRequestId() {
    let store = PendingStore(paths: tmpPaths())
    #expect(throws: (any Error).self) { try store.write(request("../evil")) }
    #expect(store.read(requestId: "../evil") == nil)
}

@Test func storeRemoveMatchingTouchesOnlyThatSessionAndKey() throws {
    let store = PendingStore(paths: tmpPaths())
    try store.write(request("a", session: "s1", key: "k1"))
    try store.write(request("b", session: "s1", key: "k2"))
    try store.write(request("c", session: "s2", key: "k1"))
    try store.write(request("d", session: "s1", tool: "Edit", key: "k1"))
    store.removeMatching(sessionId: "s1", toolName: "Bash", matchKey: "k1")
    #expect(Set(store.readAll().map(\.requestId)) == ["b", "c", "d"])
    store.removeAll(sessionId: "s1")
    #expect(store.readAll().map(\.requestId) == ["c"])
}

@Test func sweepDropsExpiredDeadAndOrphans() throws {
    let paths = tmpPaths()
    let store = PendingStore(paths: paths)
    try store.write(request("expired", expires: 500))
    try store.write(request("dead", pid: 999))
    try store.write(request("ok"))
    try store.writeAnswer(AnswerPayload(decision: "allow"), requestId: "ok")
    try store.writeAnswer(AnswerPayload(decision: "allow"), requestId: "orphan")
    store.sweep(now: 1000, isAlive: { $0 != 999 })
    #expect(store.readAll().map(\.requestId) == ["ok"])
    #expect(store.readAnswer(requestId: "ok") != nil)
    #expect(store.readAnswer(requestId: "orphan") == nil)
}
