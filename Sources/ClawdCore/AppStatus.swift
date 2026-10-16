import Foundation

/// On-disk representation of `~/.clawd/app.json`: the running app's heartbeat and visibility,
/// used by `clawd-hook` to decide whether the app needs to be launched.
public struct AppStatus: Codable, Sendable, Equatable {
    public var pid: Int32
    public var visible: Bool
    public var heartbeat: Int64
    public var version: String

    public init(pid: Int32, visible: Bool, heartbeat: Int64, version: String) {
        self.pid = pid
        self.visible = visible
        self.heartbeat = heartbeat
        self.version = version
    }
}

public struct AppStatusStore: Sendable {
    private let paths: ClawdPaths

    public init(paths: ClawdPaths) {
        self.paths = paths
    }

    public func read() -> AppStatus? {
        guard let data = try? Data(contentsOf: paths.appStatusFile) else { return nil }
        return try? JSONDecoder().decode(AppStatus.self, from: data)
    }

    public func write(_ status: AppStatus) throws {
        try FileManager.default.createDirectory(at: paths.clawdHome, withIntermediateDirectories: true)
        try atomicWrite(JSONEncoder().encode(status), to: paths.appStatusFile)
    }
}
