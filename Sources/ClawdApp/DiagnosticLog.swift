import ClawdCore
import Darwin
import Foundation

/// A debug-only trace of what the pet is showing, appended to `~/.clawd/app.log` -- but only
/// while `~/.clawd/debug` exists (create it to turn logging on, delete it to turn it off;
/// no restart needed). One line per snapshot/presentation change plus notable events
/// (`exited`, `interrupted`, `dismissed`, ...), so behavior can be verified without looking
/// at the screen. All file work happens on a private background queue.
final class DiagnosticLog: Sendable {
    static let shared = DiagnosticLog(paths: ClawdPaths.fromEnvironment())

    private let logFile: URL
    private let flagFile: URL
    private let queue = DispatchQueue(label: "local.clawd.pet.log", qos: .utility)

    init(paths: ClawdPaths) {
        logFile = paths.clawdHome.appendingPathComponent("app.log")
        flagFile = paths.clawdHome.appendingPathComponent("debug")
    }

    func log(_ message: String) {
        let now = Date()
        queue.async { [logFile, flagFile] in
            guard FileManager.default.fileExists(atPath: flagFile.path) else { return }
            let stamp = now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            let line = Data("\(stamp) \(message)\n".utf8)
            let fd = open(logFile.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            defer { close(fd) }
            _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
    }
}
