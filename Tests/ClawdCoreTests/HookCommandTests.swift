import Foundation
import Testing
@testable import ClawdCore

/// Records every call made through `AppLauncher` so tests can assert on side effects
/// without ever actually opening a URL or killing a real process. Single-threaded per
/// test, so plain mutable state under `@unchecked Sendable` is fine.
final class FakeLauncher: AppLauncher, @unchecked Sendable {
    var opened: [URL] = []
    var killed: [Int32] = []
    /// Runs on every `open`, e.g. to play a responsive app writing a fresh heartbeat.
    var onOpen: ((URL) -> Void)?

    func open(url: URL) {
        opened.append(url)
        onOpen?(url)
    }

    func kill(pid: Int32) {
        killed.append(pid)
    }
}

/// A made-up process table: which pids are alive, what they run, when they started, and
/// who their parents are. Anything not listed is dead.
struct FakeProcesses: ProcessInspecting {
    struct Proc {
        var path: String
        var start: Int64?
        var parent: Int32 = 1
    }
    var table: [Int32: Proc]

    func isAlive(_ pid: Int32) -> Bool { table[pid] != nil }
    func startTime(of pid: Int32) -> Int64? { table[pid]?.start }
    func executablePath(of pid: Int32) -> String? { table[pid]?.path }
    func ancestors(of pid: Int32, maxDepth: Int) -> [Int32] {
        var result: [Int32] = []
        var current = pid
        while result.count < maxDepth, let parent = table[current]?.parent, parent > 1 {
            result.append(parent)
            current = parent
        }
        return result
    }
}

let clawdExecutable = "/Users/u/Applications/Clawd.app/Contents/MacOS/Clawd"

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

/// F1 (critical): app.json outlives Clawd (quit, crash, reboot), and its pid can be reused
/// by any process. Here it names this test process -- alive, but not Clawd. Whether its
/// heartbeat looks stale or fresh, `/pet` must just launch Clawd and never kill anything.
@Test func petNeverKillsAnUnrelatedProcessHoldingTheRecordedPid() throws {
    for heartbeat in [Int64(0), 999_000] {
        for startTime in [Int64?.none, ProcessTools.startTime(of: getpid())] {
            let (paths, env) = tmpEnv()
            let fake = FakeLauncher()
            try AppStatusStore(paths: paths).write(
                AppStatus(pid: getpid(), visible: true, heartbeat: heartbeat, version: "1", startTime: startTime)
            )

            let r = HookCommand.run(arguments: ["pet"], stdin: Data(), environment: env, now: 999_999, hookParentPid: 1, launcher: fake)
            let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as! [String: String]
            #expect(obj["reason"] == "Clawd 已显示", "heartbeat=\(heartbeat) startTime=\(String(describing: startTime))")
            #expect(fake.killed.isEmpty, "heartbeat=\(heartbeat) startTime=\(String(describing: startTime))")
            #expect(fake.opened == [URL(string: "clawd://show")!])
        }
    }
}

@Test func petSendsToAVerifiedLiveClawd() throws {
    let (paths, env) = tmpEnv()
    let fake = FakeLauncher()
    let processes = FakeProcesses(table: [4242: .init(path: clawdExecutable, start: 1_000)])
    try AppStatusStore(paths: paths).write(AppStatus(pid: 4242, visible: true, heartbeat: 999_000, version: "1", startTime: 1_000))

    let r = HookCommand.run(arguments: ["pet"], stdin: Data(), environment: env, now: 999_999, hookParentPid: 1, launcher: fake, processes: processes)
    let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as! [String: String]
    #expect(obj["reason"] == "Clawd 已隐藏")
    #expect(fake.killed.isEmpty)
    #expect(fake.opened == [URL(string: "clawd://hide")!])
}

/// The pid runs a Clawd, but not the one that wrote app.json (it started later): unverified,
/// so launch (which reaches whichever Clawd is running) and kill nothing.
@Test func petNeverKillsAClawdWithADifferentStartTime() throws {
    let (paths, env) = tmpEnv()
    let fake = FakeLauncher()
    let processes = FakeProcesses(table: [4242: .init(path: clawdExecutable, start: 9_000)])
    try AppStatusStore(paths: paths).write(AppStatus(pid: 4242, visible: true, heartbeat: 0, version: "1", startTime: 1_000))

    let r = HookCommand.run(arguments: ["pet"], stdin: Data(), environment: env, now: 999_999, hookParentPid: 1, launcher: fake, processes: processes)
    let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as! [String: String]
    #expect(obj["reason"] == "Clawd 已显示")
    #expect(fake.killed.isEmpty)
    #expect(fake.opened == [URL(string: "clawd://show")!])
}

/// F3: a verified Clawd whose heartbeat is stale is sent the request first; if no fresh
/// heartbeat arrives within the probe window it really is hung, so it's killed and relaunched.
@Test func petRestartsAVerifiedClawdThatDoesNotAnswerTheProbe() throws {
    let (paths, env) = tmpEnv()
    let fake = FakeLauncher()
    let processes = FakeProcesses(table: [4242: .init(path: clawdExecutable, start: 1_000)])
    try AppStatusStore(paths: paths).write(AppStatus(pid: 4242, visible: false, heartbeat: 0, version: "1", startTime: 1_000))

    let started = Date()
    let r = HookCommand.run(
        arguments: ["pet"], stdin: Data(), environment: env, now: 999_999, hookParentPid: 1,
        launcher: fake, processes: processes, probeTimeout: 0.2
    )
    let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as! [String: String]
    #expect(obj["reason"] == "Clawd 无响应，已重启并显示")
    #expect(fake.killed == [4242])
    #expect(fake.opened == [URL(string: "clawd://show")!, URL(string: "clawd://show")!])
    #expect(Date().timeIntervalSince(started) >= 0.2)
}

/// F3: App Nap can hold a healthy, hidden Clawd's heartbeat back past the stale threshold.
/// It answers the probe URL with a fresh heartbeat, and must not be killed.
@Test func petNeverKillsAClawdThatAnswersTheProbe() throws {
    let (paths, env) = tmpEnv()
    let store = AppStatusStore(paths: paths)
    let fake = FakeLauncher()
    fake.onOpen = { url in
        try? store.write(AppStatus(pid: 4242, visible: url.host == "show", heartbeat: 999_999, version: "1", startTime: 1_000))
    }
    let processes = FakeProcesses(table: [4242: .init(path: clawdExecutable, start: 1_000)])
    try store.write(AppStatus(pid: 4242, visible: false, heartbeat: 0, version: "1", startTime: 1_000))

    let r = HookCommand.run(
        arguments: ["toggle"], stdin: Data(), environment: env, now: 999_999, hookParentPid: 1,
        launcher: fake, processes: processes, probeTimeout: 5
    )
    #expect(r.stdout == "Clawd 已显示\n")
    #expect(fake.killed.isEmpty)
    #expect(fake.opened == [URL(string: "clawd://show")!])
}

/// If the pid stops being Clawd while the probe waits, nothing is killed (just relaunched).
@Test func petRechecksIdentityBeforeKilling() throws {
    let (paths, env) = tmpEnv()
    final class Flip: ProcessInspecting, @unchecked Sendable {
        var calls = 0
        func isAlive(_ pid: Int32) -> Bool { calls += 1; return calls == 1 }
        func startTime(of pid: Int32) -> Int64? { 1_000 }
        func executablePath(of pid: Int32) -> String? { clawdExecutable }
        func ancestors(of pid: Int32, maxDepth: Int) -> [Int32] { [] }
    }
    let fake = FakeLauncher()
    try AppStatusStore(paths: paths).write(AppStatus(pid: 4242, visible: true, heartbeat: 0, version: "1", startTime: 1_000))

    _ = HookCommand.run(
        arguments: ["pet"], stdin: Data(), environment: env, now: 999_999, hookParentPid: 1,
        launcher: fake, processes: Flip(), probeTimeout: 0.1
    )
    #expect(fake.killed.isEmpty)
    #expect(fake.opened == [URL(string: "clawd://hide")!, URL(string: "clawd://hide")!])
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
