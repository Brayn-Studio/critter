import Foundation
import Testing
@testable import CritterCore

private let fullInput = #"""
{"session_id":"s1","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},
 "context_window":{"context_window_size":1000000,"used_percentage":38.2,"remaining_percentage":61.8},
 "rate_limits":{"five_hour":{"used_percentage":16,"resets_at":1792330000},
                "seven_day":{"used_percentage":39.4,"resets_at":1792800000}}}
"""#

/// Records what the status line wrapper handed to the "user's command" and plays back a canned answer.
final class FakeShell: ShellRunning, @unchecked Sendable {
    var calls: [(command: String, stdin: Data)] = []
    var reply: (stdout: Data, exitCode: Int32)
    init(stdout: String = "LINE", exitCode: Int32 = 0) {
        reply = (Data(stdout.utf8), exitCode)
    }
    func run(command: String, stdin: Data) -> (stdout: Data, exitCode: Int32) {
        calls.append((command, stdin))
        return reply
    }
}

private func tmpPaths() -> CritterPaths {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("critter-statusline-tests-\(UUID().uuidString)")
    return CritterPaths(critterHome: base.appendingPathComponent(".critter"), claudeHome: base.appendingPathComponent(".claude"))
}

@Test func statusLineParsesRateLimitsAndContext() {
    let r = StatusLineRecord.parse(Data(fullInput.utf8), now: 5)!
    #expect(r.sessionId == "s1" && r.updatedAt == 5)
    #expect(r.modelId == "claude-opus-5-5" && r.modelDisplayName == "Opus 5.5")
    #expect(r.contextWindowSize == 1_000_000 && r.contextUsedPercentage == 38.2)
    #expect(r.fiveHour == RateWindow(usedPercentage: 16, resetsAt: 1_792_330_000_000))
    #expect(r.sevenDay == RateWindow(usedPercentage: 39.4, resetsAt: 1_792_800_000_000))
}

@Test func statusLineMissingOrNullFieldsAreNil() {
    let r = StatusLineRecord.parse(Data(#"{"session_id":"s1","context_window":{"used_percentage":null}}"#.utf8), now: 1)!
    #expect(r.contextUsedPercentage == nil && r.fiveHour == nil && r.sevenDay == nil && r.modelId == nil)
}

@Test func statusLineCommandRunsOriginalWithSameStdin() {
    let paths = tmpPaths()
    let shell = FakeShell(stdout: "LINE", exitCode: 0)
    let result = StatusLineCommand.run(
        arguments: ["statusline", "--", "bash /x/statusline.sh"],
        stdin: Data(fullInput.utf8), paths: paths, now: 9, shell: shell
    )
    #expect(shell.calls.count == 1)
    #expect(shell.calls[0].command == "bash /x/statusline.sh")
    #expect(shell.calls[0].stdin == Data(fullInput.utf8))
    #expect(result == HookResult(stdout: "", exitCode: 0, rawStdout: Data("LINE".utf8)))
    let records = StatusLineStore(paths: paths).readAll()
    #expect(records.count == 1 && records[0].sessionId == "s1")
}

@Test func statusLineCommandWithGarbageStdinStillRunsOriginal() {
    let paths = tmpPaths()
    let shell = FakeShell(stdout: "LINE", exitCode: 0)
    let result = StatusLineCommand.run(
        arguments: ["statusline", "--", "orig"], stdin: Data("not json".utf8), paths: paths, now: 1, shell: shell
    )
    #expect(shell.calls.count == 1)
    #expect(result == HookResult(stdout: "", exitCode: 0, rawStdout: Data("LINE".utf8)))
    #expect(StatusLineStore(paths: paths).readAll().isEmpty)
}

@Test func statusLineWithoutOriginalPrintsNothing() {
    let paths = tmpPaths()
    let shell = FakeShell()
    let result = StatusLineCommand.run(arguments: ["statusline"], stdin: Data(fullInput.utf8), paths: paths, now: 1, shell: shell)
    #expect(result == HookResult(stdout: "", exitCode: 0))
    #expect(shell.calls.isEmpty)
    #expect(StatusLineStore(paths: paths).readAll().count == 1)
}

@Test func statusLineRejectsBadSessionId() {
    let paths = tmpPaths()
    let shell = FakeShell()
    let input = #"{"session_id":"../x"}"#
    let result = StatusLineCommand.run(arguments: ["statusline", "--", "orig"], stdin: Data(input.utf8), paths: paths, now: 1, shell: shell)
    #expect(shell.calls.count == 1)
    #expect(result.rawStdout == Data("LINE".utf8))
    #expect(!FileManager.default.fileExists(atPath: paths.critterHome.deletingLastPathComponent().appendingPathComponent("x.json").path))
    #expect(StatusLineStore(paths: paths).readAll().isEmpty)
}

/// The original command's output goes out byte for byte -- also bytes that aren't UTF-8.
@Test func statusLinePassesInvalidUTF8Through() {
    let shell = FakeShell()
    shell.reply = (Data([0x41, 0xFF, 0x42]), 0)
    let result = StatusLineCommand.run(
        arguments: ["statusline", "--", "orig"], stdin: Data(fullInput.utf8), paths: tmpPaths(), now: 1, shell: shell
    )
    #expect(result.rawStdout == Data([0x41, 0xFF, 0x42]))
    #expect(result.exitCode == 0)
}

@Test func statusLinePassesOriginalExitCode() {
    let shell = FakeShell(stdout: "", exitCode: 2)
    let result = StatusLineCommand.run(
        arguments: ["statusline", "--", "orig"], stdin: Data(fullInput.utf8), paths: tmpPaths(), now: 1, shell: shell
    )
    #expect(result.exitCode == 2)
}

@Test func systemShellEchoesStdinAndReportsExitCode() {
    let big = Data(repeating: 0x61, count: 300_000)
    let r = SystemShell().run(command: "cat; exit 3", stdin: big)
    #expect(r.stdout == big && r.exitCode == 3)
}
