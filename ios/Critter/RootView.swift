import CritterClient
import SwiftUI

/// The pairing screen until the phone is paired, then the home screen. A pairing link opened while paired brings the
/// pairing screen back over it (pairing again replaces the pairing only once the new one has succeeded). A tap on a
/// notification while it is there goes back to the home screen, which opens what the notification is about -- unless
/// a pairing is under way or a link waits there. The board opens by itself only while the home screen is up.
struct RootView: View {
    let store: BridgeStore
    let deviceName: String
    @Binding var link: IncomingPairLink?
    @Environment(BoardAutoOpen.self) private var autoOpen
    @Environment(NotificationRouter.self) private var router
    /// Paired, and pairing again.
    @State private var pairingAgain = Self.startsPairingAgain

    private var showsHome: Bool { store.pairing != nil && !pairingAgain }

    var body: some View {
        Group {
            if !showsHome {
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
        .onChange(of: showsHome, initial: true) { _, shown in autoOpen.homeShown(shown) }
        .onChange(of: router.target, initial: true) { _, target in
            guard target != nil else { return }
            // Not paired: nothing to open, and not later for another Mac either.
            if store.pairing == nil {
                router.target = nil
            } else if pairingAgain, store.pairingPhase == nil, link == nil {
                pairingAgain = false
            }
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
