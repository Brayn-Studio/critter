import Foundation
import Testing
@testable import ClawdCore

/// A tiny lock-protected value box so `@Sendable` watcher callbacks can report back to the
/// test body.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Polls `condition` every 10 ms until it holds or `timeout` elapses.
private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

private func tmpDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("clawd-watch-\(UUID().uuidString)")
}

@Test func directoryWatcherFiresOnAtomicRename() async throws {
    let dir = tmpDir() // deliberately not created: the watcher creates it
    let fired = Box(0)
    let watcher = DirectoryWatcher(url: dir, queue: DispatchQueue(label: "test.dir")) { fired.value += 1 }
    watcher.start()
    defer { watcher.stop() }
    #expect(FileManager.default.fileExists(atPath: dir.path))

    let tmp = dir.appendingPathComponent(".a.json.tmp")
    try Data("{}".utf8).write(to: tmp)
    try FileManager.default.moveItem(at: tmp, to: dir.appendingPathComponent("a.json"))

    #expect(await waitUntil(timeout: 1) { fired.value > 0 })
}

@Test func directoryWatcherStopsFiringAfterStop() async throws {
    let dir = tmpDir()
    let fired = Box(0)
    let watcher = DirectoryWatcher(url: dir, queue: DispatchQueue(label: "test.dir2")) { fired.value += 1 }
    watcher.start()
    watcher.stop()
    try Data("{}".utf8).write(to: dir.appendingPathComponent("b.json"))
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(fired.value == 0)
}

@Test func processExitWatcherFires() async throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sleep")
    p.arguments = ["30"]
    try p.run()
    let pid = p.processIdentifier

    let exited = Box<[Int32]>([])
    let watcher = ProcessExitWatcher(queue: DispatchQueue(label: "test.proc")) { exited.value.append($0) }
    watcher.watch(pid: pid)
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(exited.value.isEmpty)

    p.terminate()
    #expect(await waitUntil(timeout: 1) { exited.value.contains(pid) })
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(exited.value == [pid]) // exactly once
}

@Test func processExitWatcherFiresImmediatelyForDeadPid() async throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try p.run()
    p.waitUntilExit()
    let pid = p.processIdentifier

    let exited = Box<[Int32]>([])
    let watcher = ProcessExitWatcher(queue: DispatchQueue(label: "test.proc2")) { exited.value.append($0) }
    watcher.watch(pid: pid)
    #expect(await waitUntil(timeout: 0.2) { exited.value.contains(pid) })
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(exited.value == [pid]) // exactly once
}

@Test func processExitWatcherUnwatchSuppressesCallback() async throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sleep")
    p.arguments = ["30"]
    try p.run()
    let pid = p.processIdentifier

    let exited = Box<[Int32]>([])
    let watcher = ProcessExitWatcher(queue: DispatchQueue(label: "test.proc3")) { exited.value.append($0) }
    watcher.watch(pid: pid)
    watcher.unwatch(pid: pid)
    p.terminate()
    p.waitUntilExit()
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(exited.value.isEmpty)
}

@Test func appendWatcherDeliversTail() async throws {
    let dir = tmpDir()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("t.jsonl")
    try Data("{\"type\":\"assistant\"}\n".utf8).write(to: file)

    let delivered = Box<Data?>(nil)
    let watcher = FileAppendWatcher(url: file, queue: DispatchQueue(label: "test.append")) { delivered.value = $0 }
    watcher.start()
    defer { watcher.stop() }

    let line = #"{"type":"user","interruptedMessageId":"msg_x"}"# + "\n"
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(line.utf8))
    try handle.close()

    #expect(await waitUntil(timeout: 1) { delivered.value != nil })
    let tail = try #require(delivered.value)
    #expect(tail.count <= FileAppendWatcher.maxTailBytes)
    #expect(String(decoding: tail, as: UTF8.self).hasSuffix(line))
}

@Test func tailIsCappedAt16KB() throws {
    let dir = tmpDir()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("big.jsonl")
    let big = String(repeating: "x", count: 40_000) + "\nlast\n"
    try Data(big.utf8).write(to: file)
    let tail = try #require(FileAppendWatcher.readTail(of: file))
    #expect(tail.count == 16 * 1024)
    #expect(String(decoding: tail, as: UTF8.self).hasSuffix("\nlast\n"))
}
