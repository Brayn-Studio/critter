import CritterClient
import Observation

/// What the screens show of the app's access to the local network: `LocalNetworkAccess.shared` (fed by the Bonjour
/// lookups and the connections), on the main actor. Denied, the home screen's offline card, the manual entry and an
/// unreachable pairing's failure page say so with 「去设置」 (`LocalNetworkDenial.line`).
@MainActor @Observable
final class LocalNetworkStatus {
    static let shared = LocalNetworkStatus()

    private(set) var denied = false

    private init() {
        let access = LocalNetworkAccess.shared
        // Heard first, then read: a change in between is not missed.
        access.observe { denied in
            Task { @MainActor in LocalNetworkStatus.shared.denied = denied }
        }
        #if DEBUG
        // `-critterLocalNetworkDenied`: the simulator never asks for the permission.
        if DebugLaunch.current.localNetworkDenied { access.sawDenied() }
        #endif
        denied = access.denied
    }
}
