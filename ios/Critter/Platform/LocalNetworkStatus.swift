import CritterClient
import Observation

/// What the screens show of the app's access to the local network: `LocalNetworkAccess.shared` (fed by the Bonjour
/// lookups and the connections), on the main actor. Denied, the home screen's offline card, the manual entry and an
/// unreachable pairing's failure page say so with 「去设置」 (`LocalNetworkDenial.line`).
@MainActor @Observable
final class LocalNetworkStatus {
    static let shared = LocalNetworkStatus()

    private(set) var denied = false

    /// `-critterLocalNetworkDenied` (DEBUG builds): the simulator never asks for the permission, so the Bonjour
    /// browser there is always let browse and would take the denial back at once.
    private let forcedDenied: Bool

    private init() {
        let access = LocalNetworkAccess.shared
        #if DEBUG
        forcedDenied = DebugLaunch.current.localNetworkDenied
        #else
        forcedDenied = false
        #endif
        // Heard first, then read: a change in between is not missed. Each change hands over nothing but the news that
        // there was one: the task reads what is true when it runs, so two quick changes cannot land out of order.
        access.observe { _ in
            Task { @MainActor in LocalNetworkStatus.shared.refresh() }
        }
        refresh()
    }

    private func refresh() {
        denied = forcedDenied || LocalNetworkAccess.shared.denied
    }
}
