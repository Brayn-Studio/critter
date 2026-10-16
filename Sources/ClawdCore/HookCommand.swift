import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Performs the side effects a `ToggleAction` calls for: opening `clawd://show`/`clawd://hide`
/// via the system `open` command, and killing a hung app's process.
public protocol AppLauncher: Sendable {
    func open(url: URL)
    func kill(pid: Int32)
}

/// The real `AppLauncher` used by the `clawd-hook` binary. `-g` opens the URL without
/// bringing the target app to the foreground, since showing/hiding the pet shouldn't steal
/// focus from whatever the user is doing.
public struct SystemAppLauncher: AppLauncher {
    public init() {}

    public func open(url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", url.absoluteString]
        try? process.run()
    }

    public func kill(pid: Int32) {
        _ = Darwin.kill(pid, SIGKILL)
        let deadline = Date().addingTimeInterval(1.0)
        while ProcessTools.isAlive(pid), Date() < deadline {
            usleep(20_000)
        }
    }
}

/// What `clawd-hook` printed to stdout, and the exit code it reported (which per the
/// Global Constraints is always 0 -- a misbehaving hook must never block Claude Code).
public struct HookResult: Equatable, Sendable {
    public let stdout: String
    public let exitCode: Int32

    public init(stdout: String, exitCode: Int32) {
        self.stdout = stdout
        self.exitCode = exitCode
    }
}

/// All of `clawd-hook`'s logic: decoding a hook event and folding it into session state
/// (`event`), or deciding how to fulfil a `/pet` toggle request (`pet`/`toggle`). `main.swift`
/// is a thin shell around `run`.
public enum HookCommand {
    public static func run(
        arguments: [String],
        stdin: Data,
        environment: [String: String],
        now: Int64,
        hookParentPid: Int32,
        launcher: AppLauncher,
        processes: ProcessInspecting = SystemProcesses()
    ) -> HookResult {
        let paths = ClawdPaths.fromEnvironment(environment)

        switch arguments.first {
        case "event":
            runEvent(stdin: stdin, paths: paths, now: now, hookParentPid: hookParentPid)
            return HookResult(stdout: "", exitCode: 0)

        case "pet":
            let message = runToggle(stdin: stdin, paths: paths, now: now, launcher: launcher, processes: processes, fallbackEvent: "pet")
            let obj: [String: String] = ["decision": "block", "reason": message]
            let data = try? JSONSerialization.data(withJSONObject: obj)
            let stdout = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return HookResult(stdout: stdout, exitCode: 0)

        case "toggle":
            let message = runToggle(stdin: stdin, paths: paths, now: now, launcher: launcher, processes: processes, fallbackEvent: "toggle")
            return HookResult(stdout: message + "\n", exitCode: 0)

        default:
            return HookResult(stdout: "", exitCode: 0)
        }
    }

    // MARK: - event

    private static func runEvent(stdin: Data, paths: ClawdPaths, now: Int64, hookParentPid: Int32) {
        guard let input = try? JSONDecoder().decode(HookInput.self, from: stdin) else { return }

        let registry = ClaudeRegistry.entries(in: paths.claudeSessionsDir)
        let located = ClaudeProcessLocator.locate(sessionId: input.sessionId, registry: registry, hookParentPid: hookParentPid)

        let store = StateStore(paths: paths)
        var taken: ReducerAction = .ignore
        try? store.update(sessionId: input.sessionId) { previous in
            let action = StateReducer.reduce(previous: previous, input: input, now: now, pid: located?.pid, pidStartTime: located?.startTime)
            taken = action
            return action
        }

        logIfEnabled(paths: paths, sessionId: input.sessionId, event: input.hookEventName, suffix: describe(taken), now: now)
    }

    private static func describe(_ action: ReducerAction) -> String {
        switch action {
        case .write(let record): return "write:\(record.state.rawValue)"
        case .delete: return "delete"
        case .ignore: return "ignore"
        }
    }

    // MARK: - pet / toggle

    private static func runToggle(
        stdin: Data,
        paths: ClawdPaths,
        now: Int64,
        launcher: AppLauncher,
        processes: ProcessInspecting,
        fallbackEvent: String
    ) -> String {
        let input = try? JSONDecoder().decode(HookInput.self, from: stdin)
        let status = AppStatusStore(paths: paths).read()
        let appRunning = status.map { isRunningClawd($0, processes: processes) } ?? false
        let action = ToggleDecision.decide(request: .toggle, status: status, appRunning: appRunning, now: now)

        perform(action: action, status: status, launcher: launcher)

        logIfEnabled(
            paths: paths,
            sessionId: input?.sessionId ?? "-",
            event: input?.hookEventName ?? fallbackEvent,
            suffix: String(describing: action),
            now: now
        )

        return ToggleDecision.message(for: action)
    }

    /// Whether `status.pid` is still the Clawd that wrote `status` (never just "some live pid").
    private static func isRunningClawd(_ status: AppStatus, processes: ProcessInspecting) -> Bool {
        ToggleDecision.isClawd(
            status: status,
            alive: processes.isAlive(status.pid),
            executablePath: processes.executablePath(of: status.pid),
            startTime: processes.startTime(of: status.pid)
        )
    }

    private static func perform(action: ToggleAction, status: AppStatus?, launcher: AppLauncher) {
        switch action {
        case .launch(let show), .send(let show):
            launcher.open(url: URL(string: show ? "clawd://show" : "clawd://hide")!)
        case .restart(let show):
            if let pid = status?.pid {
                launcher.kill(pid: pid)
            }
            launcher.open(url: URL(string: show ? "clawd://show" : "clawd://hide")!)
        }
    }

    // MARK: - diagnostic logging

    /// Writes one line to `~/.clawd/hook.log`, but only when `~/.clawd/debug` exists --
    /// this is strictly an opt-in diagnostic, never written during normal operation.
    private static func logIfEnabled(paths: ClawdPaths, sessionId: String, event: String, suffix: String, now: Int64) {
        let debugFlag = paths.clawdHome.appendingPathComponent("debug")
        guard FileManager.default.fileExists(atPath: debugFlag.path) else { return }

        try? FileManager.default.createDirectory(at: paths.clawdHome, withIntermediateDirectories: true)
        let logFile = paths.clawdHome.appendingPathComponent("hook.log")
        rotateIfNeeded(logFile)

        let timestamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(now) / 1000))
        appendLine("\(timestamp) \(sessionId) \(event) -> \(suffix)\n", to: logFile)
    }

    /// 1 MiB. Checked (and rotated) before each append so the log can never grow unbounded.
    private static let maxLogSize: off_t = 1_048_576

    private static func rotateIfNeeded(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_size > maxLogSize else { return }
        let rotated = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".1")
        _ = rename(url.path, rotated.path)
    }

    /// Appends via `O_APPEND`, which keeps concurrent writers from a storm of hook
    /// processes from clobbering each other (each `write(2)` call is atomic).
    private static func appendLine(_ line: String, to url: URL) {
        let fd = open(url.path, O_CREAT | O_WRONLY | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = line.withCString { cString in
            Darwin.write(fd, cString, strlen(cString))
        }
    }
}
