import Foundation
import Network
import os

/// Tells the store that the network changed, so it can reconnect at once instead of waiting out the backoff
/// (spec §8.3: "网络变化时立刻重连一次").
public protocol NetworkWatching: Sendable {
    /// One value each time the network has come back or moved. Ends when the stream is no longer listened to.
    func changes() -> AsyncStream<Void>
}

/// `NWPathMonitor`, watching the system's default path. It reports a path that is usable (`.satisfied`) and
/// not the one it saw last: Wi-Fi coming back, another network, a new interface. Updates that change nothing the
/// phone cares about, and a path that is gone, report nothing.
public struct NWPathNetworkWatcher: NetworkWatching {
    public init() {}

    public func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            let filter = OSAllocatedUnfairLock(initialState: PathChangeFilter<NWPath>())
            monitor.pathUpdateHandler = { path in
                let fires = filter.withLock { $0.shouldFire(satisfied: path.status == .satisfied, path: path) }
                if fires { continuation.yield() }
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "local.critter.network-watcher"))
        }
    }
}

/// The rule behind `NWPathNetworkWatcher`, apart from the system: fire for a path that is usable and differs from
/// the last one seen (of any kind, so coming back after a loss counts even on the same network).
struct PathChangeFilter<Path: Equatable & Sendable>: Sendable {
    private var last: Path?

    mutating func shouldFire(satisfied: Bool, path: Path) -> Bool {
        defer { last = path }
        return satisfied && path != last
    }
}
