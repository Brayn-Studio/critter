import Foundation
import os
import Testing
@testable import CritterCore

private func tmpPaths() -> CritterPaths {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("critter-tests-\(UUID().uuidString)")
    return CritterPaths(critterHome: base.appendingPathComponent(".critter"), claudeHome: base.appendingPathComponent(".claude"))
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
    let status = AppStatus(pid: 123, visible: true, heartbeat: 456, version: "1.0", startTime: 1_792_000_000)
    try store.write(status)
    #expect(store.read() == status)
}

@Test func appStatusDecodesFilesWrittenBeforeStartTimeExisted() throws {
    let old = #"{"pid":123,"visible":true,"heartbeat":456,"version":"0.1.0"}"#
    let status = try JSONDecoder().decode(AppStatus.self, from: Data(old.utf8))
    #expect(status == AppStatus(pid: 123, visible: true, heartbeat: 456, version: "0.1.0", startTime: nil))
}

/// Critter removes app.json when it quits, but only its own: if another instance has
/// already overwritten it, that one's status must survive.
@Test func appStatusDeleteOnlyRemovesTheOwnersFile() throws {
    let store = AppStatusStore(paths: tmpPaths())
    try store.write(AppStatus(pid: 123, visible: true, heartbeat: 456, version: "1", startTime: 77))
    store.delete(ifOwnedBy: 999)
    #expect(store.read()?.pid == 123)
    store.delete(ifOwnedBy: 123)
    #expect(store.read() == nil)
    store.delete(ifOwnedBy: 123) // already gone: a no-op, not a crash
    #expect(store.read() == nil)
}

@Test func concurrentDeleteAndWriteNeverCorruptStateOrLock() throws {
    let paths = tmpPaths()
    let s = StateStore(paths: paths)
    try s.update(sessionId: "a") { _ in .write(rec("a", .idle, t: 0)) }

    let errors = OSAllocatedUnfairLock(initialState: [Error]())

    DispatchQueue.concurrentPerform(iterations: 200) { i in
        do {
            if i.isMultiple(of: 10) {
                s.delete(sessionId: "a")
            } else {
                try s.update(sessionId: "a") { _ in .write(rec("a", .running, t: Int64(i))) }
            }
        } catch {
            errors.withLock { $0.append(error) }
        }
    }

    #expect(errors.withLock { $0 }.isEmpty)

    // The state file must be either absent or hold valid, decodable JSON -- never corrupt.
    let stateFile = paths.stateFile(sessionId: "a")!
    if FileManager.default.fileExists(atPath: stateFile.path) {
        let data = try Data(contentsOf: stateFile)
        #expect((try? JSONDecoder().decode(SessionRecord.self, from: data)) != nil)
    }

    // A deterministic, sequential delete() afterward must still never remove the lock file:
    // flock binds to the vnode, not the path, so unlinking it would let a concurrent
    // open(O_CREAT) hand out a lock on a fresh inode and defeat mutual exclusion. (Checking
    // this only after the concurrent storm, rather than inside it, keeps the assertion
    // deterministic instead of depending on which operation happens to finish last.)
    s.delete(sessionId: "a")
    let lockFile = paths.locksDir.appendingPathComponent("a.lock")
    #expect(FileManager.default.fileExists(atPath: lockFile.path))
}

@Test func standaloneDeleteSerializesWithUpdate() throws {
    let s = StateStore(paths: tmpPaths())
    try s.update(sessionId: "a") { _ in .write(rec("a", .idle, t: 1)) }

    let group = DispatchGroup()
    let holding = DispatchSemaphore(value: 0)
    group.enter()
    DispatchQueue.global().async {
        try? s.update(sessionId: "a") { _ in
            holding.signal()
            Thread.sleep(forTimeInterval: 0.1)
            return .write(rec("a", .running, t: 2))
        }
        group.leave()
    }
    // Wait until the background update holds the lock (a fixed head start isn't enough
    // when the other tests keep every core busy).
    holding.wait()

    let deleteStart = Date()
    s.delete(sessionId: "a")
    let deleteDuration = Date().timeIntervalSince(deleteStart)
    group.wait()

    // If delete() did not serialize on the same lock, it would return almost immediately;
    // instead it must block until the in-flight update's 0.1s critical section finishes.
    #expect(deleteDuration > 0.05)
}

private func mode(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
}

/// A write that cannot be renamed into place (the target is a directory) fails, and the temp
/// file it wrote aside is gone -- whichever step failed.
@Test func atomicWriteNeverLeavesATempFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("critter-atomic-\(UUID().uuidString)")
    let target = dir.appendingPathComponent("taken.json")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    for permissions in [nil, 0o600] as [Int?] {
        #expect(throws: (any Error).self) { try atomicWrite(Data("x".utf8), to: target, permissions: permissions) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["taken.json"])
    }
}

/// The file has its mode from the moment it appears, and keeps it when it replaces a looser one.
/// (The temp file is created with that mode rather than chmod-ed afterwards; that part is the
/// implementation's to keep -- a test can't see the temp file between its creation and the rename.)
@Test func atomicWriteCreatesWithTheFinalMode() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("critter-atomic-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("secret.json")
    try atomicWrite(Data("a".utf8), to: file, permissions: 0o600)
    #expect(mode(file) == 0o600)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    try atomicWrite(Data("b".utf8), to: file, permissions: 0o600)
    #expect(mode(file) == 0o600)
    #expect(try Data(contentsOf: file) == Data("b".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["secret.json"])
}
