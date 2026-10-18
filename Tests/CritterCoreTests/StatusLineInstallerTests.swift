import Foundation
import Testing
@testable import CritterCore

private let hook = "/Users/u/.critter/bin/critter-hook"

private func literal(_ s: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return String(data: try! encoder.encode(s), encoding: .utf8)!
}

@Test func wrapUnwrapRoundTripsTrickyCommands() {
    for original in ["bash /Users/apple/.claude/statusline-command.sh",
                     #"bash -c 'echo "hi"' | cat"#,
                     "echo $HOME && printf '%s' x",
                     "/Users/u/路径 带空格/脚本.sh"] {
        #expect(StatusLineInstaller.unwrap(StatusLineInstaller.wrap(original: original, hookPath: hook), hookPath: hook) == .original(original))
    }
    #expect(StatusLineInstaller.unwrap(StatusLineInstaller.wrap(original: nil, hookPath: hook), hookPath: hook) == .original(nil))
    #expect(StatusLineInstaller.unwrap("bash x.sh", hookPath: hook) == .notWrapped)
}

@Test func wrappedCommandRunsTheOriginalThroughTheShell() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("critter-wrap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let script = dir.appendingPathComponent("fake hook's.sh")
    try "#!/bin/sh\nprintf '%s' \"$3\"\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let original = #"echo 'a b' "c""#
    let wrapped = StatusLineInstaller.wrap(original: original, hookPath: script.path)
    let r = SystemShell().run(command: wrapped, stdin: Data())
    #expect(String(decoding: r.stdout, as: UTF8.self) == original)
}

@Test func installReplacesOnlyTheCommandString() {
    let settings = "{\n    \"model\": \"opus\",\n    \"statusLine\": {\"type\": \"command\", \"command\": \"bash /x.sh\", \"padding\": 0},\n    \"tui\": {\"名字\": \"中文\"}\n}\n"
    let out = try! StatusLineInstaller.install(settings: settings, hookPath: hook)
    let expected = literal(StatusLineInstaller.wrap(original: "bash /x.sh", hookPath: hook))
    #expect(out == settings.replacingOccurrences(of: "\"bash /x.sh\"", with: expected))
}

@Test func installIsIdempotent() throws {
    let settings = "{\n  \"statusLine\": {\"type\": \"command\", \"command\": \"bash /x.sh\"}\n}\n"
    let once = try StatusLineInstaller.install(settings: settings, hookPath: hook)
    #expect(once != settings)
    #expect(try StatusLineInstaller.install(settings: once, hookPath: hook) == once)
}

@Test func installInsertsWhenAbsentAndUninstallRestoresBytes() throws {
    let s = "{\n  \"model\": \"opus\"\n}\n"
    let installed = try StatusLineInstaller.install(settings: s, hookPath: hook)
    let obj = try JSONSerialization.jsonObject(with: Data(installed.utf8)) as! [String: Any]
    let line = obj["statusLine"] as! [String: Any]
    #expect(line["type"] as? String == "command")
    #expect(line["command"] as? String == StatusLineInstaller.wrap(original: nil, hookPath: hook))
    #expect(try StatusLineInstaller.uninstall(settings: installed, hookPath: hook) == s)
}

@Test func installInsertsIntoEmptyObjectAndUninstallRemovesIt() throws {
    let installed = try StatusLineInstaller.install(settings: "{}", hookPath: hook)
    #expect(StatusLineInstaller.status(settings: installed, hookPath: hook) == .installed)
    let back = try StatusLineInstaller.uninstall(settings: installed, hookPath: hook)
    let obj = try JSONSerialization.jsonObject(with: Data(back.utf8)) as! [String: Any]
    #expect(obj.isEmpty)
}

@Test func uninstallRemovesInsertedMemberThatIsNotLast() throws {
    // Hand-edited after install: the member we added now has siblings on both sides.
    let wrapped = literal(StatusLineInstaller.wrap(original: nil, hookPath: hook))
    let s = "{\n  \"a\": 1,\n  \"statusLine\": {\"type\": \"command\", \"command\": \(wrapped)},\n  \"b\": 2\n}\n"
    let back = try StatusLineInstaller.uninstall(settings: s, hookPath: hook)
    #expect(back == "{\n  \"a\": 1,\n  \"b\": 2\n}\n")
    let first = "{\n  \"statusLine\": {\"type\": \"command\", \"command\": \(wrapped)},\n  \"b\": 2\n}\n"
    #expect(try StatusLineInstaller.uninstall(settings: first, hookPath: hook) == "{\n  \"b\": 2\n}\n")
}

@Test func uninstallRestoresOriginalValue() throws {
    let settings = "{\n\t\"statusLine\":{ \"type\":\"command\",\"command\":\"bash 'a b'/x.sh \\\"q\\\"\" },\n\t\"z\": [1, 2]\n}"
    let installed = try StatusLineInstaller.install(settings: settings, hookPath: hook)
    #expect(try StatusLineInstaller.uninstall(settings: installed, hookPath: hook) == settings)
}

@Test func installRefusesNonCommandType() {
    let s = "{\"statusLine\": {\"type\": \"static\"}}"
    #expect(throws: StatusLineInstaller.Failure.notCommandType) {
        try StatusLineInstaller.install(settings: s, hookPath: hook)
    }
}

@Test func installRefusesUnparsable() {
    #expect(throws: StatusLineInstaller.Failure.unparsable) {
        try StatusLineInstaller.install(settings: "{ not json", hookPath: hook)
    }
}

@Test func statusReportsEachCase() throws {
    let plain = "{\"statusLine\": {\"type\": \"command\", \"command\": \"bash x\"}}"
    #expect(StatusLineInstaller.status(settings: plain, hookPath: hook) == .notInstalled)
    #expect(StatusLineInstaller.status(settings: "{}", hookPath: hook) == .notInstalled)
    #expect(StatusLineInstaller.status(settings: "{\"statusLine\": {\"type\": \"static\"}}", hookPath: hook) == .otherType)
    let installed = try StatusLineInstaller.install(settings: plain, hookPath: hook)
    #expect(StatusLineInstaller.status(settings: installed, hookPath: hook) == .installed)
}

private func tmpEnv() -> (paths: CritterPaths, env: [String: String]) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("critter-installer-tests-\(UUID().uuidString)")
    let critterHome = base.appendingPathComponent(".critter")
    let claudeHome = base.appendingPathComponent(".claude")
    let env = ["CRITTER_HOME": critterHome.path, "CLAUDE_CONFIG_DIR": claudeHome.path, "HOME": base.path]
    return (CritterPaths(critterHome: critterHome, claudeHome: claudeHome), env)
}

private func runCLI(_ sub: String, env: [String: String], now: Int64 = 42) -> HookResult {
    HookCommand.run(arguments: [sub], stdin: Data(), environment: env, now: now, hookParentPid: 1, launcher: FakeLauncher())
}

@Test func cliInstallWritesBackupAndSettings() throws {
    let (paths, env) = tmpEnv()
    try FileManager.default.createDirectory(at: paths.claudeHome, withIntermediateDirectories: true)
    let original = "{\n  \"statusLine\": {\"type\": \"command\", \"command\": \"bash /x.sh\"}\n}\n"
    try original.write(to: paths.claudeSettingsFile, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.claudeSettingsFile.path)

    let result = runCLI("statusline-install", env: env)
    #expect(result.exitCode == 0 && !result.stdout.isEmpty)
    let backup = try String(contentsOf: paths.backupDir.appendingPathComponent("settings.json.42"), encoding: .utf8)
    #expect(backup == original)
    let written = try String(contentsOf: paths.claudeSettingsFile, encoding: .utf8)
    #expect(StatusLineInstaller.status(settings: written, hookPath: paths.binDir.appendingPathComponent("critter-hook").path) == .installed)
    let perms = try FileManager.default.attributesOfItem(atPath: paths.claudeSettingsFile.path)[.posixPermissions] as? Int
    #expect(perms == 0o600)

    let undone = runCLI("statusline-uninstall", env: env, now: 43)
    #expect(undone.exitCode == 0)
    #expect(try String(contentsOf: paths.claudeSettingsFile, encoding: .utf8) == original)
}

@Test func cliInstallRefusesWithExitOne() throws {
    let (paths, env) = tmpEnv()
    try FileManager.default.createDirectory(at: paths.claudeHome, withIntermediateDirectories: true)
    try "{ not json".write(to: paths.claudeSettingsFile, atomically: true, encoding: .utf8)
    let result = runCLI("statusline-install", env: env)
    #expect(result.exitCode == 1 && !result.stdout.isEmpty)
    #expect(try String(contentsOf: paths.claudeSettingsFile, encoding: .utf8) == "{ not json")
    #expect(runCLI("statusline-install", env: tmpEnv().env).exitCode == 1) // no settings.json at all
}
