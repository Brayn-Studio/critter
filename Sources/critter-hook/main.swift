import CritterCore
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Reads all of stdin, but gives up after `seconds` if nothing arrives -- so a bare
/// invocation with no pipe or redirect (stdin attached to a terminal) doesn't hang forever.
/// Once at least one byte is available we read to EOF, which is immediate for the pipes
/// Claude Code's hooks actually use.
private func readStdin(timeoutSeconds: Double) -> Data {
    var fds = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
    let result = poll(&fds, 1, Int32(timeoutSeconds * 1000))
    guard result > 0, Int32(fds.revents) & POLLIN != 0 else { return Data() }
    return FileHandle.standardInput.readDataToEndOfFile()
}

let arguments = Array(CommandLine.arguments.dropFirst())

// `pet`/`toggle` never need stdin content to decide anything (the toggle decision comes
// from ~/.critter/app.json), so they must not read it at all -- only `event`, `ask` and
// `statusline` do, and even then only up to a 2s timeout.
let readsStdin = ["event", "ask", "statusline"].contains(arguments.first ?? "")
let stdinData: Data = readsStdin ? readStdin(timeoutSeconds: 2.0) : Data()

let now = Int64(Date().timeIntervalSince1970 * 1000)

let result = HookCommand.run(
    arguments: arguments,
    stdin: stdinData,
    environment: ProcessInfo.processInfo.environment,
    now: now,
    hookParentPid: getppid(),
    launcher: SystemAppLauncher()
)

if !result.stdout.isEmpty {
    FileHandle.standardOutput.write(Data(result.stdout.utf8))
}

exit(result.exitCode)
