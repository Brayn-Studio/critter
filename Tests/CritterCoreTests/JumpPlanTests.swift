import Foundation
import Testing
@testable import CritterCore

@Test func terminalWithTtyTargetsTab() {
    #expect(JumpPlanner.plan(guiAncestor: AppHit(pid: 5, bundleId: "com.apple.Terminal"), source: .terminal, cwd: "/a", tty: "/dev/ttys003", ideLocks: []) == .terminalTab(tty: "/dev/ttys003"))
}

@Test func vscodeOpensMatchingWorkspace() {
    let locks = [IDELock(pid: 1, workspaceFolders: ["/Users/apple/CODESPACE/RoboCup"], ideName: "Visual Studio Code")]
    #expect(JumpPlanner.plan(guiAncestor: AppHit(pid: 9, bundleId: "com.microsoft.VSCode"), source: .vscode, cwd: "/Users/apple/CODESPACE/RoboCup/src", tty: nil, ideLocks: locks) == .openFolder(bundleId: "com.microsoft.VSCode", folder: "/Users/apple/CODESPACE/RoboCup"))
}

@Test func cliInsideVSCodeTerminalOpensVSCode() {
    // `claude` typed into VS Code's integrated terminal: source is the CLI, but the GUI
    // ancestor is VS Code (or a fork), so the editor window for that folder is the target.
    #expect(JumpPlanner.plan(guiAncestor: AppHit(pid: 9, bundleId: "com.microsoft.VSCode"), source: .terminal, cwd: "/w/proj", tty: "/dev/ttys009", ideLocks: []) == .openFolder(bundleId: "com.microsoft.VSCode", folder: "/w/proj"))
    #expect(JumpPlanner.plan(guiAncestor: AppHit(pid: 9, bundleId: "com.todesktop.230313mzl4w4u92"), source: .terminal, cwd: "/w/proj", tty: "/dev/ttys009", ideLocks: []) == .openFolder(bundleId: "com.todesktop.230313mzl4w4u92", folder: "/w/proj"))
}

@Test func desktopWithoutAncestorActivatesClaude() {
    #expect(JumpPlanner.plan(guiAncestor: nil, source: .desktop, cwd: "/a", tty: nil, ideLocks: []) == .activateBundle("com.anthropic.claudefordesktop"))
}

@Test func scriptsEscapeTty() {
    let tty = #"/dev/tty"x\y"#
    let terminal = JumpPlanner.terminalScript(tty: tty)
    #expect(terminal.contains(#"tty of t is "/dev/tty\"x\\y""#))
    #expect(terminal.contains("set selected of t to true"))
    #expect(terminal.contains("set index of w to 1"))
    #expect(terminal.contains("activate"))

    let iterm = JumpPlanner.itermScript(tty: tty)
    #expect(iterm.contains(#"tty of s is "/dev/tty\"x\\y""#))
    #expect(iterm.contains("select s"))
    #expect(iterm.contains("activate"))
}

@Test func itermWithTtyTargetsSession() {
    #expect(JumpPlanner.plan(guiAncestor: AppHit(pid: 5, bundleId: "com.googlecode.iterm2"), source: .terminal, cwd: "/a", tty: "/dev/ttys004", ideLocks: []) == .itermSession(tty: "/dev/ttys004"))
}

@Test func terminalsWithoutTtyAndOtherAppsJustActivate() {
    #expect(JumpPlanner.plan(guiAncestor: AppHit(pid: 5, bundleId: "com.apple.Terminal"), source: .terminal, cwd: "/a", tty: nil, ideLocks: []) == .activate(pid: 5))
    #expect(JumpPlanner.plan(guiAncestor: AppHit(pid: 6, bundleId: "com.mitchellh.ghostty"), source: .terminal, cwd: "/a", tty: "/dev/ttys001", ideLocks: []) == .activate(pid: 6))
    #expect(JumpPlanner.plan(guiAncestor: AppHit(pid: 7, bundleId: nil), source: .other, cwd: "/a", tty: nil, ideLocks: []) == .activate(pid: 7))
}

@Test func noAncestorFallsBackBySource() {
    let locks = [IDELock(pid: 1, workspaceFolders: ["/w"], ideName: "Visual Studio Code")]
    #expect(JumpPlanner.plan(guiAncestor: nil, source: .vscode, cwd: "/w/a", tty: nil, ideLocks: locks) == .openFolder(bundleId: "com.microsoft.VSCode", folder: "/w"))
    #expect(JumpPlanner.plan(guiAncestor: nil, source: .vscode, cwd: "/elsewhere", tty: nil, ideLocks: locks) == .openFolder(bundleId: "com.microsoft.VSCode", folder: "/elsewhere"))
    #expect(JumpPlanner.plan(guiAncestor: nil, source: .terminal, cwd: "/a", tty: "/dev/ttys001", ideLocks: []) == JumpPlan.none)
    #expect(JumpPlanner.plan(guiAncestor: nil, source: .other, cwd: "/a", tty: nil, ideLocks: []) == JumpPlan.none)
}

@Test func unknownFolderNeverOpensAnEmptyPath() {
    // A session whose cwd is unknown can't name a folder to open: focus the editor instead.
    #expect(JumpPlanner.plan(guiAncestor: AppHit(pid: 9, bundleId: "com.microsoft.VSCode"), source: .vscode, cwd: "", tty: nil, ideLocks: []) == .activate(pid: 9))
    #expect(JumpPlanner.plan(guiAncestor: nil, source: .vscode, cwd: "", tty: nil, ideLocks: []) == .activateBundle("com.microsoft.VSCode"))
}

@Test func workspacePicksLongestFolderThatContainsCwd() {
    let locks = [
        IDELock(pid: 1, workspaceFolders: ["/w", "/x"], ideName: nil),
        IDELock(pid: 2, workspaceFolders: ["/w/proj/"], ideName: nil),
        IDELock(pid: 3, workspaceFolders: ["/w/pro"], ideName: nil),
    ]
    #expect(JumpPlanner.workspace(for: "/w/proj/src", locks: locks) == "/w/proj/")
    #expect(JumpPlanner.workspace(for: "/w/proj", locks: locks) == "/w/proj/")
    // "/w/pro" is a string prefix of "/w/project" but not a folder that contains it.
    #expect(JumpPlanner.workspace(for: "/w/project", locks: locks) == "/w")
    #expect(JumpPlanner.workspace(for: "/y", locks: locks) == nil)
    #expect(JumpPlanner.workspace(for: "", locks: locks) == nil)
}

@Test func guiAncestorIsTheNearestRegularApp() {
    let apps: [Int32: AppHit] = [30: AppHit(pid: 30, bundleId: "com.microsoft.VSCode"), 40: AppHit(pid: 40, bundleId: "x")]
    #expect(JumpPlanner.guiAncestor(ancestors: [10, 20, 30, 40, 1], app: { apps[$0] }) == AppHit(pid: 30, bundleId: "com.microsoft.VSCode"))
    #expect(JumpPlanner.guiAncestor(ancestors: [10, 1], app: { apps[$0] }) == nil)
}
