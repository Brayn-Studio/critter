import CritterClient
import CritterKit
import SwiftUI
import UIKit

@main
struct CritterApp: App {
    /// Only for the orientations (`OrientationLock`).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: BridgeStore
    @State private var settings = PhoneSettings()
    @State private var skins = SkinStore()
    /// A `critter-pair://` link the app was opened with, until the pairing screen takes it.
    @State private var link: IncomingPairLink?
    /// `pair.deviceName`.
    private let deviceName: String

    init() {
        #if DEBUG
        let launch = DebugLaunch.current
        _store = State(initialValue: launch.fixtureStore() ?? Self.makeStore())
        _link = State(initialValue: launch.pairURI
            .flatMap { PairingURI(string: $0.absoluteString) }
            .map { IncomingPairLink(uri: $0, confirmed: true) })
        deviceName = launch.deviceName ?? UIDevice.current.name
        #else
        _store = State(initialValue: Self.makeStore())
        deviceName = UIDevice.current.name
        #endif
    }

    var body: some Scene {
        WindowGroup {
            content
                .environment(\.reduceMotion, settings.motionReduced)
                .environment(settings)
                .environment(skins)
                .environment(OrientationLock.shared)
                .onChange(of: settings.forcedSkin, initial: true) { _, name in skins.setForced(name) }
                .onChange(of: store.snapshot, initial: true) { _, snapshot in
                    if let snapshot { skins.update(from: snapshot, store: store) }
                }
                .onOpenURL { url in
                    // Not a pairing link (or a broken one): ignored.
                    guard let uri = PairingURI(string: url.absoluteString) else { return }
                    link = IncomingPairLink(uri: uri, confirmed: false)
                }
                #if DEBUG
                .task {
                    if DebugLaunch.current.frameLog { FrameLog.start() }
                    guard let url = DebugLaunch.current.openURL else { return }
                    // Once the scene is up: the system hands the URL back through `onOpenURL`.
                    try? await Task.sleep(for: .seconds(1))
                    await UIApplication.shared.open(url)
                }
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: store.sceneBecameActive()
            case .background: store.sceneEnteredBackground()
            default: break
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        if DebugLaunch.current.gallery {
            Gallery()
        } else {
            RootView(store: store, deviceName: deviceName, link: $link)
        }
        #else
        RootView(store: store, deviceName: deviceName, link: $link)
        #endif
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
                // This link's own device only: once the pairing is replaced, it has no credentials and no address.
                let current: @Sendable () -> (StoredPairing, Credentials)? = {
                    guard let (stored, credentials) = storage.load(), stored.deviceId == pairing.deviceId else { return nil }
                    return (stored, credentials)
                }
                return BridgeClient(
                    transport: transport,
                    // The stored address, read before each connection: where the Mac was last reached, also when it
                    // moved during this run (the store saves the address of every connection made).
                    endpoint: FallbackResolver(
                        lastGood: { current()?.0.endpoint }, macName: pairing.macName, browser: BonjourBrowser()
                    ),
                    fingerprint: pairing.fingerprint,
                    credentials: { current()?.1 },
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
    let uri: PairingURI
    /// Pair without asking first: only `-critterPairURI` (DEBUG builds). A link from outside is always confirmed.
    let confirmed: Bool
}
