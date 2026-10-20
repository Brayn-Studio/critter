import CoreServices
import Foundation

public struct CodexRolloutOwner: Sendable, Equatable {
    public var path: String
    public var pid: Int32
    public var startTime: Int64?
    /// Current process ancestry, which can differ from the rollout's creation client.
    public var entrypoint: String?

    public init(path: String, pid: Int32, startTime: Int64?, entrypoint: String? = nil) {
        self.path = path
        self.pid = pid
        self.startTime = startTime
        self.entrypoint = entrypoint
    }
}

/// Only live Codex processes' open rollouts count as sessions. No recursive history scan,
/// modification-time heuristic, subprocess, or Codex configuration changes are needed.
public enum CodexDiscovery {
    private static let executableNames: Set<String> = ["codex", "codex-aarch64-apple-darwin", "codex-x86_64-apple-darwin"]
    public static func openRollouts(in sessionsDir: URL) -> [CodexRolloutOwner] {
        var owners: [String: CodexRolloutOwner] = [:]
        for pid in ProcessTools.allPids().sorted() {
            guard let executable = ProcessTools.executablePath(of: pid),
                  executableNames.contains(URL(fileURLWithPath: executable).lastPathComponent) else { continue }
            let start = ProcessTools.startTime(of: pid)
            let ancestry = [executable] + ProcessTools.ancestors(of: pid, maxDepth: 24).compactMap { ProcessTools.executablePath(of: $0) }
            let entrypoint = runtimeEntrypoint(executablePaths: ancestry) ?? (ProcessTools.tty(of: pid) == nil ? nil : "codex-cli")
            for path in ProcessTools.openFilePaths(of: pid) {
                let file = URL(fileURLWithPath: path)
                guard file.lastPathComponent.hasPrefix("rollout-"), file.pathExtension == "jsonl",
                      CritterPaths.isFile(path, under: [sessionsDir]), owners[path] == nil else { continue }
                owners[path] = CodexRolloutOwner(path: path, pid: pid, startTime: start, entrypoint: entrypoint)
            }
        }
        return owners.values.sorted { $0.path < $1.path }
    }

    static func runtimeEntrypoint(executablePaths: [String]) -> String? {
        let editors: Set<String> = ["Visual Studio Code.app", "Visual Studio Code - Insiders.app", "VSCodium.app", "Cursor.app", "Windsurf.app", "Antigravity.app"]
        let terminals: Set<String> = ["Terminal.app", "iTerm.app", "WezTerm.app", "Ghostty.app", "Warp.app", "Alacritty.app"]
        // The terminal/editor hosting a bundled binary takes precedence over the app
        // directory the binary was installed in. Fall back to packaging for headless hosts.
        let ordered = Array(executablePaths.dropFirst()) + Array(executablePaths.prefix(1))
        for path in ordered {
            let components = URL(fileURLWithPath: path).pathComponents
            if components.contains("Codex.app") || components.contains("ChatGPT.app") { return "codex-desktop" }
            if components.contains(where: editors.contains) { return "codex-vscode" }
            if components.contains(where: terminals.contains) { return "codex-cli" }
        }
        return nil
    }
}

/// Recursive filesystem notifications also discover resumed rollouts in older date
/// directories. Queue-confined like MonitorEngine; no timer wakes an idle app.
public final class CodexDirectoryWatcher {
    private final class Callback {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
    }
    private var stream: FSEventStreamRef?

    public init(url: URL, queue: DispatchQueue, onChange: @escaping () -> Void) {
        let info = Unmanaged.passRetained(Callback(onChange)).toOpaque()
        var context = FSEventStreamContext(version: 0, info: info, retain: nil, release: { info in
            if let info { Unmanaged<Callback>.fromOpaque(info).release() }
        }, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().action()
        }, &context, [url.resolvingSymlinksInPath().path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            if !FSEventStreamStart(stream) {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        } else {
            Unmanaged<Callback>.fromOpaque(info).release()
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
