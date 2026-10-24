import CritterClient
import CritterKit
import SwiftUI

// What the pairing pages share (the mockups' "首次引导与配对", Android `StepLayout`): a big title and a sentence under
// it, a patch of meadow with Sprig on it, a red note when something did not work, and the network they pair over.

/// The side margin of a pairing page.
let stepGutter: CGFloat = 24

/// A page's big title (24 pt, black weight; Android `StepTitle`).
struct StepTitle: View {
    let text: String
    var color: Color = Theme.ink

    var body: some View {
        Text(verbatim: text)
            .font(.nunito(size: 24, weight: .black))
            .tracking(0.24)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The sentence under a title (14.5 pt on a 1.65 line; Android `StepBody`).
struct StepBody: View {
    let text: String
    var color: Color = Theme.ink2
    var alignment: TextAlignment = .leading

    var body: some View {
        Text(verbatim: text)
            .font(.nunito(size: 14.5, weight: .semibold))
            .lineSpacing(14.5 * (1.65 - 1.36))
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
            .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }
}

/// A page's picture (Android `StepStage`): Sprig in `state` on a patch of meadow `height` tall with 6 pt steps, 5 pt a
/// cell, standing 30 pt above the bottom; the sky follows the clock. Always the bundled Sprig, whatever skin the phone
/// wears.
struct StepStage: View {
    let state: PetState
    var height: CGFloat = 210
    var control: CritterStageControl?

    @Environment(SkinStore.self) private var skins

    var body: some View {
        LonePet(
            skin: skins.previewLibrary.manifest(PhoneSkinLibrary.fallback), state: state, cell: 5, groundInset: 30,
            control: control
        )
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(PixelShape(step: 6))
    }
}

/// Why something did not work, on a red card (Android `ErrorNote`, the mockups' error cards), with a small wilted
/// Sprig beside it unless a big one already stands above (`pet`). Read out when it appears or changes.
struct ErrorNote: View {
    let text: String
    var pet = true
    /// 12.5 pt on a 19 pt line; the failure page says it larger.
    var size: CGFloat = 12.5

    var body: some View {
        HStack(spacing: 10) {
            if pet { MiniPet(state: .error) }
            Text(verbatim: text)
                .font(.nunito(size: size, weight: .bold))
                .lineSpacing(size * (1.52 - 1.36))
                .foregroundStyle(Theme.err)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, pet ? 10 : 14)
        .padding(.top, pet ? 8 : 12)
        .padding(.bottom, pet ? 10 : 14)
        .pixelSurface(fill: Theme.errBg, lip: Theme.errBg, step: 3, lipHeight: 0)
        .accessibilityElement(children: .combine)
        .onChange(of: text, initial: true) { _, text in
            AccessibilityNotification.Announcement(text).post()
        }
    }
}

/// The bundled Sprig, live, 2 pt a cell, in a 40 × 40 box (the portraits' 20 × 20 cells), never dimmed.
private struct MiniPet: View {
    let state: PetState

    @Environment(SkinStore.self) private var skins

    private static let cell: CGFloat = 2

    var body: some View {
        let side = CGFloat(Portraits.cells) * Self.cell
        CritterStage(slots: [
            CritterSlot(
                sessionId: LonePet.petId, manifest: skins.previewLibrary.manifest(PhoneSkinLibrary.fallback),
                state: state, activity: nil, dimStrength: 0, origin: CGPoint(x: Self.cell, y: side), scale: Self.cell
            ),
        ])
        .frame(width: side, height: side)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// `host:port`, an IPv6 host in brackets.
func hostAndPort(_ host: String, _ port: UInt16) -> String {
    host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
}

/// How the pairing screen finds the Macs on the network and reads a Mac's certificate fingerprint before trusting it:
/// Bonjour and a TLS probe, or the fakes `-critterPairing` asks for (DEBUG).
struct PairingNetwork {
    var browser: any MacBrowser
    var probe: @Sendable (Endpoint) async -> String?

    static let live = PairingNetwork(browser: BonjourBrowser()) { endpoint in
        await CertificateProbe(transport: URLSessionTransport()).fingerprint(of: endpoint)
    }

    /// The one this run uses.
    @MainActor static var current: PairingNetwork {
        #if DEBUG
        if let fake = DebugLaunch.current.fakePairingNetwork { return fake }
        #endif
        return .live
    }
}
