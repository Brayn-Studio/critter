import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Runs a shell command line with the given stdin and captures its stdout.
public protocol ShellRunning: Sendable {
    func run(command: String, stdin: Data) -> (stdout: Data, exitCode: Int32)
}

/// The real `ShellRunning`: `/bin/sh -c`, inheriting the environment; the command's stderr
/// goes straight to ours.
public struct SystemShell: ShellRunning {
    public init() {}

    public func run(command: String, stdin: Data) -> (stdout: Data, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.standardError
        // A command that exits without reading its stdin must not kill us with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        do { try process.run() } catch { return (Data(), 127) }

        // Written off-thread so a command that writes a lot before reading can't deadlock us.
        let writer = Thread {
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        writer.start()
        let output = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (output, process.terminationStatus)
    }
}

/// `critter-hook statusline [-- <original command>]`: records the status line data Claude Code
/// pipes in, then runs the user's original status line command with the very same stdin and
/// returns its stdout and exit code verbatim. Recording problems never affect the passthrough.
public enum StatusLineCommand {
    public static func run(
        arguments: [String],
        stdin: Data,
        paths: CritterPaths,
        now: Int64,
        shell: ShellRunning
    ) -> HookResult {
        if let record = StatusLineRecord.parse(stdin, now: now) {
            try? StatusLineStore(paths: paths).write(record)
        }
        guard arguments.count >= 3, arguments[1] == "--" else {
            return HookResult(stdout: "", exitCode: 0)
        }
        let result = shell.run(command: arguments[2], stdin: stdin)
        return HookResult(stdout: String(decoding: result.stdout, as: UTF8.self), exitCode: result.exitCode)
    }
}
