import Foundation

/// On-disk representation of `~/.critter/app.json`: the running app's heartbeat and visibility,
/// used by `critter-hook` to decide whether the app needs to be launched.
///
/// The file can outlive the app (a crash, `kill -9`, a reboot), and its `pid` can then be
/// handed to any other process -- so `pid` alone never proves Critter is running; see
/// `ToggleDecision.isCritter`.
public struct AppStatus: Codable, Sendable, Equatable {
    public var pid: Int32
    public var visible: Bool
    public var heartbeat: Int64
    public var version: String
    /// Seconds since epoch: the app process's start time (`ProcessTools.startTime`), so a
    /// later process that reused `pid` can be told apart. Absent in files written before
    /// it existed, which still decode.
    public var startTime: Int64?

    public init(pid: Int32, visible: Bool, heartbeat: Int64, version: String, startTime: Int64? = nil) {
        self.pid = pid
        self.visible = visible
        self.heartbeat = heartbeat
        self.version = version
        self.startTime = startTime
    }
}

public struct AppStatusStore: Sendable {
    private let paths: CritterPaths

    public init(paths: CritterPaths) {
        self.paths = paths
    }

    public func read() -> AppStatus? {
        guard let data = try? Data(contentsOf: paths.appStatusFile) else { return nil }
        return try? JSONDecoder().decode(AppStatus.self, from: data)
    }

    public func write(_ status: AppStatus) throws {
        try FileManager.default.createDirectory(at: paths.critterHome, withIntermediateDirectories: true)
        try atomicWrite(JSONEncoder().encode(status), to: paths.appStatusFile)
    }

    /// Removes app.json if it still belongs to `pid` (best effort; called as the app quits).
    /// A file another instance has since written is left alone.
    public func delete(ifOwnedBy pid: Int32) {
        guard read()?.pid == pid else { return }
        try? FileManager.default.removeItem(at: paths.appStatusFile)
    }
}
