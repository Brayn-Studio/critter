import CritterClient
import SwiftUI

/// The pairing screen. A placeholder with its title for now.
struct PairingView: View {
    let store: BridgeStore
    let deviceName: String
    /// A link the app was opened with; the pairing screen takes it (sets it back to nil).
    @Binding var link: IncomingPairLink?
    /// Back to the home screen; nil when there is nothing to go back to (not paired).
    let onClose: (() -> Void)?

    var body: some View {
        Text("扫 Mac 上的二维码")
            .font(.title2.bold())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
