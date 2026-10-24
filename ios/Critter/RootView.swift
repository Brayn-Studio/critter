import CritterClient
import SwiftUI

/// The first-run guide on a phone neither paired nor through it yet (`OnboardingSteps.showsAtLaunch`), or when the
/// settings open it again; otherwise the pairing screen until the phone is paired, then the home screen. A pairing link
/// opened while paired brings the pairing screen back over it (pairing again replaces the pairing only once the new one
/// has succeeded). A tap on a notification while it is there goes back to the home screen, which opens what the
/// notification is about -- unless a pairing is under way or a link waits there. The board opens by itself only while
/// the home screen is up.
struct RootView: View {
    let store: BridgeStore
    let deviceName: String
    @Binding var link: IncomingPairLink?
    @Environment(BoardAutoOpen.self) private var autoOpen
    @Environment(NotificationRouter.self) private var router
    @Environment(PhoneSettings.self) private var settings
    /// Paired, and pairing again.
    @State private var pairingAgain = Self.startsPairingAgain
    /// The guide is up, from this step; nil when it is not.
    @State private var guide: OnboardingStep?

    /// - Parameter guideAtLaunch: the step the guide starts at when the app comes up, nil for none (read once).
    init(store: BridgeStore, deviceName: String, link: Binding<IncomingPairLink?>, guideAtLaunch: OnboardingStep?) {
        self.store = store
        self.deviceName = deviceName
        _link = link
        _guide = State(initialValue: guideAtLaunch)
    }

    private var showsHome: Bool { guide == nil && store.pairing != nil && !pairingAgain }

    var body: some View {
        Group {
            if let start = guide {
                OnboardingView(store: store, deviceName: deviceName, link: $link, start: start) { guide = nil }
            } else if !showsHome {
                PairingView(
                    store: store, deviceName: deviceName, link: $link,
                    onClose: store.pairing == nil ? nil : { pairingAgain = false }
                )
            } else {
                HomeView(store: store, onPairAgain: { pairingAgain = true }, onGuide: { guide = .welcome })
            }
        }
        .onChange(of: link, initial: true) { _, link in
            // Paired: the link replaces the pairing, over the home screen (the guide, run again, gives way). Not paired,
            // the guide's pairing step or the pairing screen takes it.
            guard link != nil, store.pairing != nil else { return }
            guide = nil
            pairingAgain = true
        }
        .onChange(of: showsHome, initial: true) { _, shown in autoOpen.homeShown(shown) }
        .onChange(of: router.target, initial: true) { _, target in
            guard target != nil else { return }
            // Not paired: nothing to open, and not later for another Mac either.
            if store.pairing == nil {
                router.target = nil
            } else if store.pairingPhase == nil, link == nil {
                // Back to the home screen, which opens it: from pairing again, or from the guide (run again, or
                // paired on its way).
                pairingAgain = false
                if guide != nil {
                    settings.onboardingDone = true
                    guide = nil
                }
            }
        }
    }

    /// The guide at launch: on a first run (spec §8.8), or `-critterOnboarding <step>` (DEBUG) at that step.
    @MainActor
    static func guideAtLaunch(paired: Bool, settings: PhoneSettings) -> OnboardingStep? {
        #if DEBUG
        if let demo = DebugLaunch.current.onboarding { return demo.step }
        #endif
        return OnboardingSteps.showsAtLaunch(paired: paired, done: settings.onboardingDone) ? .welcome : nil
    }

    /// `-critterPairing scan|manual…` over a fixture (DEBUG): the pairing screen comes up over the home screen.
    private static var startsPairingAgain: Bool {
        #if DEBUG
        if let demo = DebugLaunch.current.pairing, demo.launchLink == nil, DebugLaunch.current.onboarding == nil {
            return true
        }
        #endif
        return false
    }
}
