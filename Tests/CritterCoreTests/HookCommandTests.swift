import Foundation
import Testing
@testable import CritterCore

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

let critterExecutable = "/Users/u/Applications/Critter.app/Contents/MacOS/Critter"

private func tmpEnv() -> (paths: CritterPaths, env: [String: String]) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("critter-hook-cmd-tests-\(UUID().uuidString)")
    let critterHome = base.appendingPathComponent(".critter")
    let claudeHome = base.appendingPathComponent(".claude")
    let env = ["CRITTER_HOME": critterHome.path, "CLAUDE_CONFIG_DIR": claudeHome.path, "HOME": base.path]
    return (CritterPaths(critterHome: critterHome, claudeHome: claudeHome), env)
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

/// F5: the hook records the session's entrypoint -- from Claude's registry entry for its
/// process, else from `CLAUDE_CODE_ENTRYPOINT`, which Claude sets in every hook's environment
/// (verified on 2.1.301: `sdk-cli` for `claude -p`, `cli` for an interactive terminal session).
@Test func eventRecordsTheEntrypoint() throws {
    let start = #"{"session_id":"s1","cwd":"/x","hook_event_name":"SessionStart","source":"startup"}"#

    // No registry entry (a `-p` run that hasn't registered): the environment decides.
    var (paths, env) = tmpEnv()
    env["CLAUDE_CODE_ENTRYPOINT"] = "sdk-cli"
    _ = HookCommand.run(arguments: ["event"], stdin: Data(start.utf8), environment: env, now: 1000, hookParentPid: 1, launcher: FakeLauncher())
    #expect(StateStore(paths: paths).read(sessionId: "s1")?.entrypoint == "sdk-cli")

    // The registry entry of the hook's own Claude takes precedence.
    (paths, env) = tmpEnv()
    let processes = FakeProcesses(table: [
        300: .init(path: "/bin/sh", start: 50, parent: 200),
        200: .init(path: "/Users/u/.local/share/claude/versions/2.1.301", start: 40),
    ])
    try FileManager.default.createDirectory(at: paths.claudeSessionsDir, withIntermediateDirectories: true)
    try #"{"pid":200,"sessionId":"s1","cwd":"/x","startedAt":40000,"entrypoint":"claude-vscode"}"#
        .write(to: paths.claudeSessionsDir.appendingPathComponent("200.json"), atomically: true, encoding: .utf8)
    _ = HookCommand.run(arguments: ["event"], stdin: Data(start.utf8), environment: env, now: 1000, hookParentPid: 300, launcher: FakeLauncher(), processes: processes)
    let record = StateStore(paths: paths).read(sessionId: "s1")
    #expect(record?.entrypoint == "claude-vscode")
    #expect(record?.claudePid == 200)
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

/// The event hook parses its stdin once, with `JSONSerialization`, and builds `HookInput` from
/// that: it must come out exactly as decoding would make it -- including which payloads fail.
@Test func hookInputFromParsedPayloadMatchesTheDecoder() throws {
    struct Fields: Equatable {
        var strings: [String?]
        var toolInput: JSONValue?
    }
    func fields(_ input: HookInput?) -> Fields? {
        input.map {
            Fields(
                strings: [$0.sessionId, $0.cwd, $0.transcriptPath, $0.hookEventName, $0.source, $0.reason, $0.prompt, $0.toolName,
                          $0.notificationType, $0.message, $0.lastAssistantMessage, $0.errorType, $0.errorMessage, $0.commandName],
                toolInput: $0.toolInput
            )
        }
    }
    let payloads = [
        #"{"session_id":"s1","cwd":"/x","transcript_path":"/t.jsonl","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls","timeout":120000,"flag":true,"list":[1,2.5,null,"x"],"nested":{"a":null}},"tool_response":{"stdout":"…"}}"#,
        #"{"session_id":"s1","cwd":"/x","hook_event_name":"Stop","last_assistant_message":"全部完成。","source":null,"tool_input":null}"#,
        #"{"session_id":"s1","cwd":"/x","hook_event_name":"Notification","notification_type":"idle_prompt","message":"waiting","reason":"r","prompt":"p","error_type":"e","error_message":"m","command_name":"c"}"#,
        #"{"session_id":"s1","cwd":"/x","hook_event_name":"Stop","message":42}"#,       // wrong type: both fail
        #"{"session_id":"s1","hook_event_name":"Stop"}"#,                              // missing cwd
        #"{"session_id":null,"cwd":"/x","hook_event_name":"Stop"}"#,
        #"{"session_id":7,"cwd":"/x","hook_event_name":"Stop"}"#,
        #"{"session_id":"s1","cwd":"/x","hook_event_name":"PreToolUse","tool_input":"just a string"}"#,
    ]
    for payload in payloads {
        let data = Data(payload.utf8)
        let decoded = try? JSONDecoder().decode(HookInput.self, from: data)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fields(HookInput(json: root)) == fields(decoded), Comment(rawValue: payload))
    }
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
    let logFile = paths.critterHome.appendingPathComponent("hook.log")
    #expect(!FileManager.default.fileExists(atPath: logFile.path))

    // With the debug flag file present, the next event appends a log line.
    try FileManager.default.createDirectory(at: paths.critterHome, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: paths.critterHome.appendingPathComponent("debug").path, contents: nil)

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
    #expect(obj["reason"] == "Critter 已显示")
    #expect(fake.opened == [URL(string: "critter://show")!])
    #expect(r.exitCode == 0)
}

@Test func togglePrintsMessageLine() {
    let (_, env) = tmpEnv()
    let fake = FakeLauncher()
    let r = HookCommand.run(arguments: ["toggle"], stdin: Data(), environment: env, now: 0, hookParentPid: 1, launcher: fake)
    #expect(r.stdout == "Critter 已显示\n")
    #expect(fake.opened == [URL(string: "critter://show")!])
}

/// F1 (critical): app.json outlives Critter (quit, crash, reboot), and its pid can be reused
/// by any process. Here it names this test process -- alive, but not Critter. Whether its
/// heartbeat looks stale or fresh, `/pet` must just launch Critter and never kill anything.
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
            #expect(obj["reason"] == "Critter 已显示", "heartbeat=\(heartbeat) startTime=\(String(describing: startTime))")
            #expect(fake.killed.isEmpty, "heartbeat=\(heartbeat) startTime=\(String(describing: startTime))")
            #expect(fake.opened == [URL(string: "critter://show")!])
        }
    }
}

@Test func petSendsToAVerifiedLiveCritter() throws {
    let (paths, env) = tmpEnv()
    let fake = FakeLauncher()
    let processes = FakeProcesses(table: [4242: .init(path: critterExecutable, start: 1_000)])
    try AppStatusStore(paths: paths).write(AppStatus(pid: 4242, visible: true, heartbeat: 999_000, version: "1", startTime: 1_000))

    let r = HookCommand.run(arguments: ["pet"], stdin: Data(), environment: env, now: 999_999, hookParentPid: 1, launcher: fake, processes: processes)
    let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as! [String: String]
    #expect(obj["reason"] == "Critter 已隐藏")
    #expect(fake.killed.isEmpty)
    #expect(fake.opened == [URL(string: "critter://hide")!])
}

/// The pid runs a Critter, but not the one that wrote app.json (it started later): unverified,
/// so launch (which reaches whichever Critter is running) and kill nothing.
@Test func petNeverKillsACritterWithADifferentStartTime() throws {
    let (paths, env) = tmpEnv()
    let fake = FakeLauncher()
    let processes = FakeProcesses(table: [4242: .init(path: critterExecutable, start: 9_000)])
    try AppStatusStore(paths: paths).write(AppStatus(pid: 4242, visible: true, heartbeat: 0, version: "1", startTime: 1_000))

    let r = HookCommand.run(arguments: ["pet"], stdin: Data(), environment: env, now: 999_999, hookParentPid: 1, launcher: fake, processes: processes)
    let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as! [String: String]
    #expect(obj["reason"] == "Critter 已显示")
    #expect(fake.killed.isEmpty)
    #expect(fake.opened == [URL(string: "critter://show")!])
}

/// F3: a verified Critter whose heartbeat is stale is sent the request first; if no fresh
/// heartbeat arrives within the probe window it really is hung, so it's killed and relaunched.
@Test func petRestartsAVerifiedCritterThatDoesNotAnswerTheProbe() throws {
    let (paths, env) = tmpEnv()
    let fake = FakeLauncher()
    let processes = FakeProcesses(table: [4242: .init(path: critterExecutable, start: 1_000)])
    try AppStatusStore(paths: paths).write(AppStatus(pid: 4242, visible: false, heartbeat: 0, version: "1", startTime: 1_000))

    let started = Date()
    let r = HookCommand.run(
        arguments: ["pet"], stdin: Data(), environment: env, now: 999_999, hookParentPid: 1,
        launcher: fake, processes: processes, probeTimeout: 0.2
    )
    let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as! [String: String]
    #expect(obj["reason"] == "Critter 无响应，已重启并显示")
    #expect(fake.killed == [4242])
    #expect(fake.opened == [URL(string: "critter://show")!, URL(string: "critter://show")!])
    #expect(Date().timeIntervalSince(started) >= 0.2)
}

/// F3: App Nap can hold a healthy, hidden Critter's heartbeat back past the stale threshold.
/// It answers the probe URL with a fresh heartbeat, and must not be killed.
@Test func petNeverKillsACritterThatAnswersTheProbe() throws {
    let (paths, env) = tmpEnv()
    let store = AppStatusStore(paths: paths)
    let fake = FakeLauncher()
    fake.onOpen = { url in
        try? store.write(AppStatus(pid: 4242, visible: url.host == "show", heartbeat: 999_999, version: "1", startTime: 1_000))
    }
    let processes = FakeProcesses(table: [4242: .init(path: critterExecutable, start: 1_000)])
    try store.write(AppStatus(pid: 4242, visible: false, heartbeat: 0, version: "1", startTime: 1_000))

    let r = HookCommand.run(
        arguments: ["toggle"], stdin: Data(), environment: env, now: 999_999, hookParentPid: 1,
        launcher: fake, processes: processes, probeTimeout: 5
    )
    #expect(r.stdout == "Critter 已显示\n")
    #expect(fake.killed.isEmpty)
    #expect(fake.opened == [URL(string: "critter://show")!])
}

/// If the pid stops being Critter while the probe waits, nothing is killed (just relaunched).
@Test func petRechecksIdentityBeforeKilling() throws {
    let (paths, env) = tmpEnv()
    final class Flip: ProcessInspecting, @unchecked Sendable {
        var calls = 0
        func isAlive(_ pid: Int32) -> Bool { calls += 1; return calls == 1 }
        func startTime(of pid: Int32) -> Int64? { 1_000 }
        func executablePath(of pid: Int32) -> String? { critterExecutable }
        func ancestors(of pid: Int32, maxDepth: Int) -> [Int32] { [] }
    }
    let fake = FakeLauncher()
    try AppStatusStore(paths: paths).write(AppStatus(pid: 4242, visible: true, heartbeat: 0, version: "1", startTime: 1_000))

    _ = HookCommand.run(
        arguments: ["pet"], stdin: Data(), environment: env, now: 999_999, hookParentPid: 1,
        launcher: fake, processes: Flip(), probeTimeout: 0.1
    )
    #expect(fake.killed.isEmpty)
    #expect(fake.opened == [URL(string: "critter://hide")!, URL(string: "critter://hide")!])
}

@Test func petLaunchesWhenStatusPidIsDead() throws {
    let (paths, env) = tmpEnv()
    let fake = FakeLauncher()
    let store = AppStatusStore(paths: paths)
    // A pid this large is essentially guaranteed not to be a running process.
    try store.write(AppStatus(pid: 999_999, visible: true, heartbeat: 999_999, version: "1"))

    let r = HookCommand.run(arguments: ["pet"], stdin: Data(), environment: env, now: 1_000_000, hookParentPid: 1, launcher: fake)
    let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as! [String: String]
    #expect(obj["reason"] == "Critter 已显示")
    #expect(fake.killed.isEmpty)
    #expect(fake.opened == [URL(string: "critter://show")!])
}

/// F7: the `open` child must not inherit the hook's stdout/stderr -- `pet`'s stdout is Claude
/// Code's JSON channel, and a child still holding the pipe keeps Claude waiting for EOF.
@Test func launcherDetachesTheOpenChildFromTheHooksOutput() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("critter-open-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let report = dir.appendingPathComponent("report.txt")
    let tool = dir.appendingPathComponent("fake-open")
    // Reports what its stdout (saved as fd 3) and stderr (fd 4) are, next to /dev/null.
    try """
    #!/bin/sh
    exec 3>&1 4>&2
    { stat -L -f '%HT %r' /dev/fd/3; stat -L -f '%HT %r' /dev/fd/4; stat -f '%HT %r' /dev/null; } > "\(report.path).tmp" 2>&1
    mv "\(report.path).tmp" "\(report.path)"
    """.write(to: tool, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

    SystemAppLauncher(openTool: tool).open(url: URL(string: "critter://show")!)

    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: report.path), Date() < deadline {
        usleep(20_000)
    }
    let lines = try String(contentsOf: report, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(lines.count == 3)
    #expect(lines.first == lines.last, "stdout: \(lines)")
    #expect(lines.dropFirst().first == lines.last, "stderr: \(lines)")
}
