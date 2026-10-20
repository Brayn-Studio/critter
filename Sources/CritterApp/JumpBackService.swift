import AppKit
import CritterCore
import os

/// Brings a session's window to the front when its Critter is clicked (spec §6.4): finds the
/// GUI app hosting the session's Claude process, picks a `JumpPlan` and carries it out --
/// AppleScript for a Terminal/iTerm2 tab, `NSWorkspace` to open a VS Code folder, and
/// activation through Launch Services for anything else.
///
/// Everything after the click runs on a background serial queue (process queries, file
/// reads and the `osascript` child process are never on the main thread). Failures are
/// silent apart from one `os_log` line (and an `app.log` line in debug mode).
@MainActor
final class JumpBackService {
    private let paths: CritterPaths
    private let queue = DispatchQueue(label: "local.critter.pet.jump", qos: .userInitiated)

    init(paths: CritterPaths) {
        self.paths = paths
    }

    func jump(to session: PetSession) {
        // Debug-only: with `debugEnabled` and `debugJumpDryRun` set, plans are logged to
        // `app.log` but not carried out (e.g. to check a Terminal session's plan without
        // sending Terminal an Apple Event).
        let defaults = UserDefaults.standard
        let dryRun = defaults.bool(forKey: "debugEnabled") && defaults.bool(forKey: "debugJumpDryRun")
        let ideDir = paths.claudeIDEDir
        queue.async {
            JumpWorker.jump(to: session, ideDir: ideDir, dryRun: dryRun)
        }
    }
}

/// The background half of `JumpBackService`; only ever called on its queue.
private enum JumpWorker {
    static let scriptTimeout: TimeInterval = 3
    static let ancestorDepth = 12
    static let logger = Logger(subsystem: "local.critter.pet", category: "jump")

    static func jump(to session: PetSession, ideDir: URL, dryRun: Bool) {
        let ancestor = session.pid.flatMap(guiAncestor(of:))
        let tty = session.pid.flatMap(ProcessTools.tty(of:))
        let plan = JumpPlanner.plan(
            guiAncestor: ancestor,
            source: session.source,
            cwd: session.cwd,
            tty: tty,
            ideLocks: session.source.isCodex ? [] : ClaudeRegistry.ideLocks(in: ideDir),
            sessionId: session.id
        )
        let host = ancestor.map { "\($0.pid):\($0.bundleId ?? "-")" } ?? "none"
        DiagnosticLog.shared.log("jump-plan \(session.id) \(describe(plan)) ancestor=\(host)" + (dryRun ? " dry-run" : ""))
        guard !dryRun else { return }

        switch plan {
        case .terminalTab(let tty):
            runScript(JumpPlanner.terminalScript(tty: tty), sessionId: session.id, fallbackPid: ancestor?.pid)
        case .itermSession(let tty):
            runScript(JumpPlanner.itermScript(tty: tty), sessionId: session.id, fallbackPid: ancestor?.pid)
        case .openFolder(let bundleId, let folder):
            openFolder(folder, bundleId: bundleId, sessionId: session.id)
        case .activate(let pid):
            activate(pid: pid, sessionId: session.id)
        case .activateBundle(let bundleId):
            activate(bundleId: bundleId, sessionId: session.id)
        case .codexThread(let id):
            if let url = URL(string: "codex://threads/\(id)"), NSWorkspace.shared.open(url) {
                DiagnosticLog.shared.log("jump-result \(session.id) opened Codex thread")
            } else if let ancestor {
                activate(pid: ancestor.pid, sessionId: session.id)
            } else {
                activate(bundleId: "com.openai.codex", sessionId: session.id)
            }
        case .none:
            break
        }
    }

    /// The nearest ancestor of `pid` that is a regular (Dock-visible) GUI app.
    static func guiAncestor(of pid: Int32) -> AppHit? {
        JumpPlanner.guiAncestor(ancestors: ProcessTools.ancestors(of: pid, maxDepth: ancestorDepth)) { candidate in
            guard let app = NSRunningApplication(processIdentifier: candidate), app.activationPolicy == .regular else {
                return nil
            }
            return AppHit(pid: candidate, bundleId: app.bundleIdentifier)
        }
    }

    // MARK: - Executing a plan

    /// Runs `source` with `/usr/bin/osascript`, killing it after `scriptTimeout`. If the
    /// script fails (e.g. the user declined the Automation permission), the hosting app is
    /// at least activated. A timeout gets no fallback: the likely cause is the permission
    /// prompt waiting for an answer, which activating another app would bury.
    static func runScript(_ source: String, sessionId: String, fallbackPid: Int32?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            fail(sessionId, "osascript could not start: \(error.localizedDescription)")
            return
        }
        guard exited.wait(timeout: .now() + scriptTimeout) == .success else {
            process.terminate()
            fail(sessionId, "osascript timed out after \(Int(scriptTimeout)) s")
            return
        }
        // Both outputs are a line or two at most, so they fit the pipe buffers and can be
        // read once the process has exited.
        let output = text(stdout)
        guard process.terminationStatus == 0 else {
            fail(sessionId, "osascript exit \(process.terminationStatus): \(text(stderr))")
            if let fallbackPid { activate(pid: fallbackPid, sessionId: sessionId) }
            return
        }
        DiagnosticLog.shared.log("jump-result \(sessionId) script \(output)")
    }

    static func openFolder(_ folder: String, bundleId: String, sessionId: String) {
        let workspace = NSWorkspace.shared
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleId) else {
            fail(sessionId, "no app for \(bundleId)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.open([URL(fileURLWithPath: folder, isDirectory: true)], withApplicationAt: appURL, configuration: configuration) { _, error in
            if let error {
                fail(sessionId, "open \(folder) with \(bundleId): \(error.localizedDescription)")
                activate(bundleId: bundleId, sessionId: sessionId)
            } else {
                DiagnosticLog.shared.log("jump-result \(sessionId) opened \(folder) with \(bundleId)")
            }
        }
    }

    /// Brings the app running as `pid` forward. Launch Services (`openApplication` with
    /// `activates`) is the primary path: since macOS 14, activation is cooperative and
    /// `NSRunningApplication.activate` requested by an app that isn't active itself -- Critter
    /// never is -- may be silently declined. The direct request is only the fallback.
    static func activate(pid: Int32, sessionId: String) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            fail(sessionId, "pid \(pid) is not a running app")
            return
        }
        guard let bundleURL = app.bundleURL else {
            activateDirectly(app, sessionId: sessionId)
            return
        }
        openApplication(at: bundleURL, sessionId: sessionId, fallback: app)
    }

    /// Activates the app with `bundleId`, launching it if it isn't running.
    static func activate(bundleId: String, sessionId: String) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            activate(pid: running.processIdentifier, sessionId: sessionId)
        } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            openApplication(at: appURL, sessionId: sessionId, fallback: nil)
        } else {
            fail(sessionId, "no app for \(bundleId)")
        }
    }

    static func openApplication(at appURL: URL, sessionId: String, fallback: NSRunningApplication?) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                fail(sessionId, "open \(appURL.lastPathComponent): \(error.localizedDescription)")
                if let fallback { activateDirectly(fallback, sessionId: sessionId) }
            } else {
                DiagnosticLog.shared.log("jump-result \(sessionId) opened \(appURL.lastPathComponent)")
            }
        }
    }

    static func activateDirectly(_ app: NSRunningApplication, sessionId: String) {
        if app.activate(options: []) {
            DiagnosticLog.shared.log("jump-result \(sessionId) activated pid=\(app.processIdentifier)")
        } else {
            fail(sessionId, "activate pid=\(app.processIdentifier) refused")
        }
    }

    // MARK: - Helpers

    static func describe(_ plan: JumpPlan) -> String {
        switch plan {
        case .terminalTab(let tty): return "plan=terminalTab tty=\(tty)"
        case .itermSession(let tty): return "plan=itermSession tty=\(tty)"
        case .openFolder(let bundleId, let folder): return "plan=openFolder app=\(bundleId) folder=\(folder)"
        case .activate(let pid): return "plan=activate pid=\(pid)"
        case .activateBundle(let bundleId): return "plan=activateBundle app=\(bundleId)"
        case .codexThread(let id): return "plan=codexThread id=\(id)"
        case .none: return "plan=none"
        }
    }

    static func fail(_ sessionId: String, _ message: String) {
        logger.error("jump \(sessionId, privacy: .public) failed: \(message, privacy: .public)")
        DiagnosticLog.shared.log("jump-result \(sessionId) failed: \(message)")
    }

    static func text(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
