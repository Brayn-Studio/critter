import Foundation
import Testing
@testable import ClawdCore

private func tmpDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clawd-registry-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func registryParsesRealShape() {
    let json = #"{"pid":20409,"sessionId":"d3331ac5-4416","cwd":"/Users/apple/CODESPACE/clawd","startedAt":1792166332523,"procStart":"Fri Oct 16 15:58:51 2026","version":"2.1.281","kind":"interactive","entrypoint":"cli","name":"clawd-c1","status":"busy","messagingSocketPath":"/tmp/cc-socks/20409.sock"}"#
    let e = ClaudeRegistry.parseEntry(Data(json.utf8))
    #expect(e == RegistryEntry(pid: 20409, sessionId: "d3331ac5-4416", cwd: "/Users/apple/CODESPACE/clawd", startedAt: 1792166332523, entrypoint: "cli", kind: "interactive", name: "clawd-c1"))
    #expect(ClaudeRegistry.parseEntry(Data("garbage".utf8)) == nil)
    #expect(ClaudeRegistry.parseEntry(Data(#"{"sessionId":"x"}"#.utf8)) == nil)
}

@Test func registryDirIgnoresKeyFilesAndCorruptFiles() throws {
    let dir = try tmpDir()
    try #"{"pid":1,"sessionId":"a","cwd":"/x"}"#.write(to: dir.appendingPathComponent("1.json"), atomically: true, encoding: .utf8)
    try "{not json".write(to: dir.appendingPathComponent("2.json"), atomically: true, encoding: .utf8)
    try "irrelevant".write(to: dir.appendingPathComponent("1.abc.key"), atomically: true, encoding: .utf8)

    let entries = ClaudeRegistry.entries(in: dir)
    #expect(entries.count == 1)
    #expect(entries.first?.sessionId == "a")
}

@Test func ideLockParse() throws {
    let dir = try tmpDir()
    let json = #"{"pid":56642,"workspaceFolders":["/Users/apple/CODESPACE/RoboCup"],"ideName":"Visual Studio Code","transport":"ws","authToken":"x"}"#
    try json.write(to: dir.appendingPathComponent("56642.lock"), atomically: true, encoding: .utf8)

    let locks = ClaudeRegistry.ideLocks(in: dir)
    #expect(locks == [IDELock(pid: 56642, workspaceFolders: ["/Users/apple/CODESPACE/RoboCup"], ideName: "Visual Studio Code")])
}

@Test func registryParsesUpdatedAt() {
    let json = #"{"pid":7,"sessionId":"s","cwd":"/x","startedAt":1000,"status":"idle","updatedAt":5000,"statusUpdatedAt":5000}"#
    #expect(ClaudeRegistry.parseEntry(Data(json.utf8))?.updatedAt == 5000)
}

private func regEntry(_ pid: Int32, _ sessionId: String = "s", startedAt: Int64?) -> RegistryEntry {
    RegistryEntry(pid: pid, sessionId: sessionId, cwd: "/x", startedAt: startedAt, entrypoint: "cli", kind: "interactive", name: nil)
}

private let claudeBinary = "/Users/u/.local/share/claude/versions/2.1.301"

/// F2: the hook's own parent chain names its Claude (spike: the hook's parent is claude). A
/// leftover registry entry for the same session -- a killed process, before `claude --resume`
/// reopened it -- must not win just because the directory listed it first.
@Test func locatorPrefersTheHooksOwnClaudeAncestor() {
    let processes = FakeProcesses(table: [
        300: .init(path: "/bin/sh", start: 50, parent: 200),
        200: .init(path: claudeBinary, start: 40, parent: 100),
        100: .init(path: "/bin/zsh", start: 10),
    ])
    let registry = [regEntry(77, startedAt: 1_000), regEntry(200, startedAt: 40_000)]

    let hit = ClaudeProcessLocator.locate(sessionId: "s", registry: registry, hookParentPid: 300, processes: processes)
    #expect(hit == LocatedClaude(pid: 200, startTime: 40, entry: registry[1]))

    // Found by its ancestry even when Claude never registered it.
    let unregistered = ClaudeProcessLocator.locate(sessionId: "s", registry: [regEntry(77, startedAt: 1_000)], hookParentPid: 300, processes: processes)
    #expect(unregistered == LocatedClaude(pid: 200, startTime: 40, entry: nil))
}

/// Without a Claude ancestor, the registry decides -- but only its live entries (not a dead
/// pid, not a pid reused since the entry was written), newest session start first.
@Test func locatorFallsBackToTheNewestLiveRegistryEntry() {
    let processes = FakeProcesses(table: [
        300: .init(path: "/bin/sh", start: 50),
        20: .init(path: claudeBinary, start: 100),
        30: .init(path: claudeBinary, start: 200),
        40: .init(path: "/usr/bin/vim", start: 900),
    ])
    let registry = [
        regEntry(10, startedAt: 300_000), // newest, but its process is gone
        regEntry(20, startedAt: 100_500),
        regEntry(30, startedAt: 200_500),
        regEntry(40, startedAt: 400_000), // pid 40 now belongs to a process started after it: reused
        regEntry(50, "other", startedAt: 500_000),
    ]

    let hit = ClaudeProcessLocator.locate(sessionId: "s", registry: registry, hookParentPid: 300, processes: processes)
    #expect(hit == LocatedClaude(pid: 30, startTime: 200, entry: registry[2]))
}

@Test func locatorReturnsNilRatherThanGuessing() {
    let processes = FakeProcesses(table: [300: .init(path: "/bin/sh", start: 50)])
    #expect(ClaudeProcessLocator.locate(sessionId: "s", registry: [regEntry(10, startedAt: 1)], hookParentPid: 300, processes: processes) == nil)
    #expect(ClaudeProcessLocator.locate(sessionId: "missing", registry: [], hookParentPid: 1) == nil)
}
