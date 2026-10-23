import CritterClient
import CritterKit
import SwiftUI
import UIKit

@main
struct CritterApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: BridgeStore
    /// A `critter-pair://` link the app was opened with, until the pairing screen takes it.
    @State private var link: IncomingPairLink?
    /// `pair.deviceName`.
    private let deviceName: String

    init() {
        #if DEBUG
        let launch = DebugLaunch.current
        _store = State(initialValue: launch.fixtureStore() ?? Self.makeStore())
        _link = State(initialValue: launch.pairURI.map { IncomingPairLink(url: $0, confirmed: true) })
        deviceName = launch.deviceName ?? UIDevice.current.name
        #else
        _store = State(initialValue: Self.makeStore())
        deviceName = UIDevice.current.name
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store, deviceName: deviceName, link: $link)
                .onOpenURL { url in
                    guard url.scheme == "critter-pair" else { return }
                    link = IncomingPairLink(url: url, confirmed: false)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: store.sceneBecameActive()
            case .background: store.sceneEnteredBackground()
            default: break
            }
        }
    }

    /// The store over the real pieces: the keychain, `wss://` to the Mac, Bonjour.
    private static func makeStore() -> BridgeStore {
        let storage = KeychainPairingStorage()
        let transport = URLSessionTransport()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let app = "critter-ios/\(version)"
        return BridgeStore(
            storage: storage,
            makeLink: { pairing, onEvent in
                BridgeClient(
                    transport: transport,
                    endpoint: FallbackResolver(lastGood: pairing.endpoint, macName: pairing.macName, browser: BonjourBrowser()),
                    fingerprint: pairing.fingerprint,
                    // This link's own device only: once the pairing is replaced, it has no credentials.
                    credentials: {
                        guard let (stored, credentials) = storage.load(), stored.deviceId == pairing.deviceId else { return nil }
                        return credentials
                    },
                    app: app,
                    onEvent: onEvent
                )
            },
            pairer: Pairer(transport: transport),
            background: UIKitBackgroundRunner()
        )
    }
}

/// A `critter-pair://` link the app was opened with, for the pairing screen to take.
struct IncomingPairLink: Equatable {
    let url: URL
    /// Pair without asking first: only `-critterPairURI` (DEBUG builds). A link from outside is always confirmed.
    let confirmed: Bool
}
