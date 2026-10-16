import Foundation

/// A GUI app found among a session's ancestor processes (the app whose window hosts it).
public struct AppHit: Equatable, Sendable {
    public var pid: Int32
    public var bundleId: String?

    public init(pid: Int32, bundleId: String?) {
        self.pid = pid
        self.bundleId = bundleId
    }
}

/// How to bring a session's window to the front when its Clawd is clicked (spec §6.4).
public enum JumpPlan: Equatable, Sendable {
    /// Terminal.app: select the tab whose tty is `tty` (AppleScript).
    case terminalTab(tty: String)
    /// iTerm2: select the session whose tty is `tty` (AppleScript).
    case itermSession(tty: String)
    /// VS Code or a fork: open `folder` with that app, which focuses the window that
    /// already has it open.
    case openFolder(bundleId: String, folder: String)
    /// Any other GUI app hosting the session: just activate it.
    case activate(pid: Int32)
    /// No hosting app was found, but the source names one (Claude Desktop, VS Code).
    case activateBundle(String)
    /// Nothing to jump to.
    case none
}

/// Pure decision logic for jumping back to a session's window: which plan fits a session
/// given the GUI app found among its Claude process's ancestors, and the AppleScript used
/// to select a Terminal/iTerm2 tab by tty. Executing a plan is the app's job.
public enum JumpPlanner {
    public static let vscodeFamily: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.google.antigravity",
        "com.exafunction.windsurf",
    ]
    public static let claudeDesktop = "com.anthropic.claudefordesktop"
    public static let terminal = "com.apple.Terminal"
    public static let iterm = "com.googlecode.iterm2"
    public static let vscode = "com.microsoft.VSCode"

    public static func plan(guiAncestor: AppHit?, source: SessionSource, cwd: String, tty: String?, ideLocks: [IDELock]) -> JumpPlan {
        let folder = workspace(for: cwd, locks: ideLocks) ?? cwd

        guard let app = guiAncestor else {
            switch source {
            case .desktop:
                return .activateBundle(claudeDesktop)
            case .vscode:
                return folder.isEmpty ? .activateBundle(vscode) : .openFolder(bundleId: vscode, folder: folder)
            case .terminal, .other:
                return .none
            }
        }

        switch (app.bundleId, tty) {
        case (terminal?, let tty?):
            return .terminalTab(tty: tty)
        case (iterm?, let tty?):
            return .itermSession(tty: tty)
        case (let bundleId?, _) where vscodeFamily.contains(bundleId) && !folder.isEmpty:
            return .openFolder(bundleId: bundleId, folder: folder)
        default:
            return .activate(pid: app.pid)
        }
    }

    /// The IDE workspace folder that contains `cwd` (the folder itself or one of its
    /// subdirectories); the longest one wins when workspaces are nested.
    public static func workspace(for cwd: String, locks: [IDELock]) -> String? {
        guard !cwd.isEmpty else { return nil }
        let target = trimmingTrailingSlashes(cwd)
        var best: (folder: String, length: Int)?
        for folder in locks.flatMap(\.workspaceFolders) {
            let base = trimmingTrailingSlashes(folder)
            guard !base.isEmpty else { continue }
            let contains = target == base || target.hasPrefix(base == "/" ? "/" : base + "/")
            guard contains, base.count > (best?.length ?? -1) else { continue }
            best = (folder, base.count)
        }
        return best?.folder
    }

    /// The nearest of `ancestors` (nearest first) that `app` recognizes as a regular GUI app.
    public static func guiAncestor(ancestors: [Int32], app: (Int32) -> AppHit?) -> AppHit? {
        for pid in ancestors {
            if let hit = app(pid) { return hit }
        }
        return nil
    }

    /// Selects Terminal.app's tab running on `tty` and brings its window forward; if no tab
    /// matches, just activates Terminal.
    public static func terminalScript(tty: String) -> String {
        """
        tell application id "\(terminal)"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(escape(tty))" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "found"
                    end if
                end repeat
            end repeat
            activate
            return "not found"
        end tell
        """
    }

    /// Selects iTerm2's session running on `tty` (and its tab and window); if no session
    /// matches, just activates iTerm2.
    public static func itermScript(tty: String) -> String {
        """
        tell application id "\(iterm)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(escape(tty))" then
                            select w
                            select t
                            select s
                            activate
                            return "found"
                        end if
                    end repeat
                end repeat
            end repeat
            activate
            return "not found"
        end tell
        """
    }

    /// Escapes `text` for use inside an AppleScript string literal.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
