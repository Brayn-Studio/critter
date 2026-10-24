import CritterClient
import SwiftUI

/// The pairing screen until the phone is paired, then the home screen. A pairing link opened while paired brings the
/// pairing screen back over it (pairing again replaces the pairing only once the new one has succeeded).
struct RootView: View {
    let store: BridgeStore
    let deviceName: String
    @Binding var link: IncomingPairLink?
    /// Paired, and pairing again.
    @State private var pairingAgain = Self.startsPairingAgain

    var body: some View {
        Group {
            if store.pairing == nil || pairingAgain {
                PairingView(
                    store: store, deviceName: deviceName, link: $link,
                    onClose: store.pairing == nil ? nil : { pairingAgain = false }
                )
            } else {
                HomeView(store: store, onPairAgain: { pairingAgain = true })
            }
        }
        .onChange(of: link, initial: true) { _, link in
            if link != nil, store.pairing != nil { pairingAgain = true }
        }
    }

    /// `-critterPairing scan|manual…` over a fixture (DEBUG): the pairing screen comes up over the home screen.
    private static var startsPairingAgain: Bool {
        #if DEBUG
        if let demo = DebugLaunch.current.pairing, demo.launchLink == nil { return true }
        #endif
        return false
    }
}
