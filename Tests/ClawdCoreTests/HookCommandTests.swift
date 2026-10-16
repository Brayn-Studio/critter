import Foundation
import Testing
@testable import ClawdCore

/// Records every call made through `AppLauncher` so tests can assert on side effects
/// without ever actually opening a URL or killing a real process. Single-threaded per
/// test, so plain mutable state under `@unchecked Sendable` is fine.
final class FakeLauncher: AppLauncher, @unchecked Sendable {
    var opened: [URL] = []
    var killed: [Int32] = []

    func open(url: URL) {
        opened.append(url)
    }

    func kill(pid: Int32) {
        killed.append(pid)
    }
}

private func tmpEnv() -> (paths: ClawdPaths, env: [String: String]) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("clawd-hook-cmd-tests-\(UUID().uuidString)")
    let clawdHome = base.appendingPathComponent(".clawd")
    let claudeHome = base.appendingPathComponent(".claude")
    let env = ["CLAWD_HOME": clawdHome.path, "CLAUDE_CONFIG_DIR": claudeHome.path, "HOME": base.path]
    return (ClawdPaths(clawdHome: clawdHome, claudeHome: claudeHome), env)
}

@Test func eventWritesStateAndPrintsNothing() {
    let (paths, env) = tmpEnv()
    let fake = FakeLauncher()
    let r = HookCommand.run(
        arguments: ["event"],
        stdin: Data(#"{"session_id":"s1","cwd":"/x","hook_event_name":"UserPromptSubmit","prompt":"hi"}"#.utf8),
        environment: env,
        now: 1000,
        hookParentPid: getpid(),
        launcher: fake
    )
    #expect(r == HookResult(stdout: "", exitCode: 0))
    #expect(StateStore(paths: paths).read(sessionId: "s1")?.state == .running)
}

@Test func garbageInputIsSilent() {
    let (paths, env) = tmpEnv()
    let fake = FakeLauncher()
    let r = HookCommand.run(
        arguments: ["event"],
        stdin: Data("nope".utf8),
        environment: env,
        now: 1000,
        hookParentPid: getpid(),
        launcher: fake
    )
    #expect(r == HookResult(stdout: "", exitCode: 0))
    #expect(StateStore(paths: paths).readAll().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: paths.sessionsDir.path))
}

@Test func unknownSubcommandPrintsNothing() {
    let (_, env) = tmpEnv()
    let fake = FakeLauncher()
    let r = HookCommand.run(arguments: ["bogus"], stdin: Data(), environment: env, now: 0, hookParentPid: 1, launcher: fake)
    #expect(r == HookResult(stdout: "", exitCode: 0))
    #expect(fake.opened.isEmpty)
}

@Test func debugLogOnlyWhenFlagFilePresent() throws {
    let (paths, env) = tmpEnv()
    let fake = FakeLauncher()

    // No debug flag file: no log should appear at all.
    _ = HookCommand.run(
        arguments: ["event"],
        stdin: Data(#"{"session_id":"s1","cwd":"/x","hook_event_name":"UserPromptSubmit","prompt":"hi"}"#.utf8),
        environment: env,
        now: 1000,
        hookParentPid: getpid(),
        launcher: fake
    )
    let logFile = paths.clawdHome.appendingPathComponent("hook.log")
    #expect(!FileManager.default.fileExists(atPath: logFile.path))

    // With the debug flag file present, the next event appends a log line.
    try FileManager.default.createDirectory(at: paths.clawdHome, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: paths.clawdHome.appendingPathComponent("debug").path, contents: nil)

    _ = HookCommand.run(
        arguments: ["event"],
        stdin: Data(#"{"session_id":"s1","cwd":"/x","hook_event_name":"UserPromptSubmit","prompt":"hi"}"#.utf8),
        environment: env,
        now: 2000,
        hookParentPid: getpid(),
        launcher: fake
    )
    let contents = try String(contentsOf: logFile, encoding: .utf8)
    let lastLine = contents.split(separator: "\n").last.map(String.init) ?? ""
    #expect(lastLine.contains("UserPromptSubmit -> write:running"))
    #expect(lastLine.contains("s1"))
}

@Test func petPrintsBlockJSONAndLaunches() {
    let (_, env) = tmpEnv()
    let fake = FakeLauncher()
    let r = HookCommand.run(arguments: ["pet"], stdin: Data(), environment: env, now: 0, hookParentPid: 1, launcher: fake)
    let obj = try! JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as! [String: String]
    #expect(obj["decision"] == "block")
    #expect(obj["reason"] == "Clawd 已显示")
    #expect(fake.opened == [URL(string: "clawd://show")!])
    #expect(r.exitCode == 0)
}

@Test func togglePrintsMessageLine() {
    let (_, env) = tmpEnv()
    let fake = FakeLauncher()
    let r = HookCommand.run(arguments: ["toggle"], stdin: Data(), environment: env, now: 0, hookParentPid: 1, launcher: fake)
    #expect(r.stdout == "Clawd 已显示\n")
    #expect(fake.opened == [URL(string: "clawd://show")!])
}

@Test func petRestartsAndKillsStaleApp() throws {
    let (paths, env) = tmpEnv()
    let fake = FakeLauncher()
    let store = AppStatusStore(paths: paths)
    // Use our own pid so `ProcessTools.isAlive` reports it as alive, but with an ancient
    // heartbeat relative to `now`: alive-but-stale is exactly the restart case.
    let myPid = getpid()
    try store.write(AppStatus(pid: myPid, visible: false, heartbeat: 0, version: "1"))

    let r = HookCommand.run(arguments: ["pet"], stdin: Data(), environment: env, now: 999_999, hookParentPid: 1, launcher: fake)
    let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as! [String: String]
    #expect(obj["reason"] == "Clawd 无响应，已重启并显示")
    #expect(fake.killed == [myPid])
    #expect(fake.opened == [URL(string: "clawd://show")!])
}

@Test func petLaunchesWhenStatusPidIsDead() throws {
    let (paths, env) = tmpEnv()
    let fake = FakeLauncher()
    let store = AppStatusStore(paths: paths)
    // A pid this large is essentially guaranteed not to be a running process.
    try store.write(AppStatus(pid: 999_999, visible: true, heartbeat: 999_999, version: "1"))

    let r = HookCommand.run(arguments: ["pet"], stdin: Data(), environment: env, now: 1_000_000, hookParentPid: 1, launcher: fake)
    let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as! [String: String]
    #expect(obj["reason"] == "Clawd 已显示")
    #expect(fake.killed.isEmpty)
    #expect(fake.opened == [URL(string: "clawd://show")!])
}
