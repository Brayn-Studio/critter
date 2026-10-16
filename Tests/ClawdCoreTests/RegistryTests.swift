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

@Test func locatorPrefersRegistry() {
    let registry = [RegistryEntry(pid: 4242, sessionId: "sess-1", cwd: "/x", startedAt: nil, entrypoint: "cli", kind: "interactive", name: nil)]

    let hit = ClaudeProcessLocator.locate(sessionId: "sess-1", registry: registry, hookParentPid: 1)
    #expect(hit?.pid == 4242)

    // pid 1 (launchd) has no ancestors and is not itself a Claude executable, so with an
    // empty registry this must return nil rather than guessing.
    let miss = ClaudeProcessLocator.locate(sessionId: "missing", registry: [], hookParentPid: 1)
    #expect(miss == nil)
}
