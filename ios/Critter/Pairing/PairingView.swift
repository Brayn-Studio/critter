import CritterClient
import CritterKit
import SwiftUI

/// Pairing (Android `PairingScreen`): scan the QR code the Mac shows, open its `critter-pair://` link (shown in a
/// confirmation first, with the Mac's name, address and fingerprint), or pick the Mac from the network and type the
/// code. Only Macs on the local network are paired with (`PrivateNetwork`, the ranges the Mac itself serves).
///
/// One attempt at a time: while one is under way (`store.pairingPhase` set), nothing starts another. The screen then
/// shows where it is, and how it failed if it did; when it succeeds the root view shows the home screen. A link that
/// comes in meanwhile waits (`queuedLink`, the latest one wins): it is taken once the attempt has failed or been
/// cancelled, and dropped without a word once it has succeeded.
struct PairingView: View {
    let store: BridgeStore
    /// `pair.deviceName`.
    let deviceName: String
    /// A link the app was opened with; the pairing screen takes it (sets it back to nil).
    @Binding var link: IncomingPairLink?
    /// Back to the home screen; nil when there is nothing to go back to (not paired).
    let onClose: (() -> Void)?

    private enum Page {
        case scan, manual
    }

    @State private var page = Page.scan
    /// Why a code or a link could not be used, or the Mac could not be reached; shown on the page.
    @State private var note: String?
    @State private var attempt: Task<Void, Never>?
    /// The attempt's request has reached the Mac (its row there is waiting for 「允许」).
    @State private var awaiting = false
    /// How the last attempt failed.
    @State private var failure: PairFailure?
    @State private var linkToConfirm: PairingURI?
    /// A link that came in while an attempt was under way.
    @State private var queuedLink: IncomingPairLink?
    /// A scanned pairing code is being taken: the frame is green and Sprig hops, then pairing starts.
    @State private var flashing = false
    /// The scanner's Sprig.
    @State private var stage = CritterStageControl()

    private let network = PairingNetwork.current

    /// How long the frame shows green after a read, before pairing starts: six beats of the pet engine.
    private static let flash: Duration = .milliseconds(360)

    var body: some View {
        content
            .overlay {
                if let uri = linkToConfirm { linkConfirmation(uri) }
            }
            .onChange(of: link, initial: true) { _, incoming in
                take(incoming)
            }
            .onChange(of: store.pairingPhase) { _, phase in
                if phase == .awaitingApproval, attempt != nil { awaiting = true }
                // A cancelled attempt is over only once the store has let go of it.
                if phase == nil { takeQueuedIfIdle() }
            }
            #if DEBUG
            .task { await debugOpenManual() }
            #endif
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            FailurePage(failure: failure, note: note, onRescan: rescan)
        } else if attempt != nil {
            WaitingPage(awaiting: awaiting, deviceName: shownDeviceName, onCancel: cancel)
        } else if page == .manual {
            ManualPairView(
                network: network, note: note, onPair: { pair($0) },
                onProbeFailed: { note = "连不上这台 Mac，换个方式或稍后再试。" },
                onScan: { switchTo(.scan) }
            )
        } else {
            ScanPage(
                note: note, flash: flashing, onCode: read, onManual: { switchTo(.manual) }, onClose: onClose,
                control: stage
            )
        }
    }

    /// The device name as the Mac shows it.
    private var shownDeviceName: String {
        BridgeProtocol.deviceName(deviceName)
    }

    /// An attempt is under way, or about to start (a scanned code flashing).
    private var busy: Bool {
        attempt != nil || store.pairingPhase != nil || flashing
    }

    // MARK: - Pairing

    /// Starts pairing with `target`, unless an attempt is under way or the Mac is not on the local network.
    /// Returns whether it started.
    @discardableResult
    private func pair(_ target: PairingTarget) -> Bool {
        guard !busy else { return false }
        guard PrivateNetwork.isAllowed(host: target.endpoint.host) else {
            note = notOnNetwork(target.endpoint.host)
            return false
        }
        note = nil
        failure = nil
        awaiting = false
        attempt = Task {
            let result = await store.pair(target, deviceName: deviceName)
            // Cancelled: the screen has moved on already.
            guard !Task.isCancelled else { return }
            attempt = nil
            switch result {
            case .paired:
                // Whatever link came meanwhile was for the pairing just made.
                queuedLink = nil
                onClose?()
            case .failed(let why):
                failure = why
                takeQueuedIfIdle()
            }
        }
        return true
    }

    /// 「取消」: closes the attempt's connection (the Mac withdraws its request) and goes back to the page. A link that
    /// came meanwhile is taken once the store has let go of the attempt.
    private func cancel() {
        attempt?.cancel()
        attempt = nil
        takeQueuedIfIdle()
    }

    private func rescan() {
        failure = nil
        switchTo(.scan)
    }

    private func switchTo(_ next: Page) {
        note = nil
        page = next
    }

    private func notOnNetwork(_ host: String) -> String {
        "地址 \(host) 不在局域网里。Critter 只和同一个局域网里的 Mac 配对。"
    }

    /// A QR code the camera read. Returns whether to keep scanning: not once a pairing code has been taken, which
    /// flashes the frame green and makes Sprig hop before pairing starts.
    private func read(_ text: String) -> Bool {
        guard !busy, linkToConfirm == nil else { return true }
        guard let uri = PairingURI(string: text) else {
            note = "这不是 Critter 的配对二维码。"
            return true
        }
        guard PrivateNetwork.isAllowed(host: uri.host) else {
            note = notOnNetwork(uri.host)
            return true
        }
        flashing = true
        stage.hop(LonePet.petId)
        Task {
            try? await Task.sleep(for: Self.flash)
            flashing = false
            pair(PairingTarget(uri: uri))
            takeQueuedIfIdle()
        }
        return false
    }

    /// A link the app was opened with: confirmed first (unless it comes from `-critterPairURI`), refused if the Mac
    /// is not on the local network, and kept for later while an attempt is under way.
    private func take(_ incoming: IncomingPairLink?) {
        guard let incoming else { return }
        link = nil
        guard !busy else {
            queuedLink = incoming
            return
        }
        linkToConfirm = nil
        guard PrivateNetwork.isAllowed(host: incoming.uri.host) else {
            note = "这个配对链接指向 \(incoming.uri.host)，不在局域网里，已忽略。"
            return
        }
        if incoming.confirmed {
            pair(PairingTarget(uri: incoming.uri))
        } else {
            linkToConfirm = incoming.uri
        }
    }

    /// The link that came during an attempt, now that the attempt is over and did not pair.
    private func takeQueuedIfIdle() {
        guard let queued = queuedLink, !busy else { return }
        queuedLink = nil
        take(queued)
    }

    // MARK: - The link's confirmation

    private func linkConfirmation(_ uri: PairingURI) -> some View {
        PixelDialog(
            title: "和这台 Mac 配对？", confirm: "配对",
            onConfirm: {
                linkToConfirm = nil
                pair(PairingTarget(uri: uri))
            },
            onDismiss: {
                linkToConfirm = nil
                onClose?()
            }
        ) {
            Text(verbatim: "一个链接要让这台手机和「\(Theme.macName(uri.name))」配对。只在你刚在 Mac 上点了「添加手机」时才继续。")
            Text(verbatim: "地址  \(hostAndPort(uri.host, uri.port))")
                .font(.nunito(size: 12.5, weight: .semibold))
            Text(verbatim: "证书指纹  \(PairingURI.fingerprintPrefix(uri.fingerprint))")
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Theme.ink)
            Text("和 Mac 上「添加手机」里码下面的指纹一致时才配对。")
                .font(.nunito(size: 12, weight: .semibold))
            if let existing = store.pairing {
                Text(verbatim: "这会替换现在和「\(Theme.macName(existing.macName))」的配对。")
                    .font(.nunito(size: 14, weight: .bold))
                    .foregroundStyle(Theme.err)
            }
        }
    }

    #if DEBUG
    /// `-critterPairing manual…`: a second after the scanner is up, 「手动输入」 is tapped.
    private func debugOpenManual() async {
        guard case .manual? = DebugLaunch.current.pairing else { return }
        try? await Task.sleep(for: .seconds(1))
        if page == .scan, !busy { switchTo(.manual) }
    }
    #endif
}
