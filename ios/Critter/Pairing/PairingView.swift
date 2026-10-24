import CritterClient
import CritterKit
import os
import SwiftUI

/// Pairing (Android `PairingScreen`): scan the QR code the Mac shows, open its `critter-pair://` link (shown in a
/// confirmation first, with the Mac's name, address and fingerprint), or pick the Mac from the network and type the
/// code. Only Macs on the local network are paired with (`PrivateNetwork`, the ranges the Mac itself serves).
///
/// In the first-run guide (`position` set) it is the pairing step: the seeds over the scanner and the pages of an attempt,
/// 「跳过」 with what skipping costs (`onSkip`, `skipNote`), 「返回」 going back a step (`onClose`), and a pairing made
/// going on to the next step (`onPaired`).
///
/// One attempt at a time: while one is under way (`store.isPairing`, or `store.pairingPhase` set), nothing starts
/// another -- also not while the store, past the Mac's answer, still stops the old connection and saves. The screen
/// then shows where it is, and how it failed if it did; when it succeeds the root view shows the home screen. A link
/// that comes in meanwhile waits (`queuedLink`, the latest one wins): it is taken once the attempt has failed or been
/// cancelled, and dropped without a word once it has succeeded.
///
/// An attempt that could not reach the Mac while the app was not active -- the 本地网络 prompt up (it fails while the
/// prompt is up, or just before it shows), or the user away turning something on -- is tried again by itself once the
/// app is active again, while its failure page is still up (`PairingRetry`, once per target). Not one that had reached
/// the Mac (`store.lastPairReachedMac`): its code is used up.
struct PairingView: View {
    let store: BridgeStore
    /// `pair.deviceName`.
    let deviceName: String
    /// A link the app was opened with; the pairing screen takes it (sets it back to nil).
    @Binding var link: IncomingPairLink?
    /// Back to the home screen; nil when there is nothing to go back to (not paired). In the guide: back a step.
    let onClose: (() -> Void)?
    /// The step's place in the first-run guide; nil outside it.
    var position: StepPosition?
    /// 「跳过」 in the guide, and what skipping costs.
    var onSkip: (() -> Void)?
    var skipNote: String?
    /// A pairing was made: the guide's next step. Without it, `onClose` (the home screen).
    var onPaired: (() -> Void)?

    private enum Page {
        case scan, manual
    }

    private static let log = Logger(subsystem: "com.braynlabs.critter", category: "pairing")

    @Environment(\.scenePhase) private var scenePhase
    @State private var page = Page.scan
    /// Why a code or a link could not be used, or the Mac could not be reached; shown on the page.
    @State private var note: String?
    @State private var attempt: Task<Void, Never>?
    /// The attempt's request has reached the Mac (its row there is waiting for 「允许」).
    @State private var awaiting = false
    /// How the last attempt failed.
    @State private var failure: PairFailure?
    /// Whether that attempt is tried again by itself when the app is active again.
    @State private var retry = PairingRetry()
    @State private var linkToConfirm: PairingURI?
    /// A link that came in while an attempt was under way.
    @State private var queuedLink: IncomingPairLink?
    /// A scanned pairing code is being taken: the frame is green and Sprig hops, then pairing starts.
    @State private var flashing = false
    /// The wait before that code is paired with: cancelled when the page is left or the screen closes during it.
    @State private var flashTask: Task<Void, Never>?
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
            .onChange(of: store.isPairing) { _, pairing in
                if !pairing { takeQueuedIfIdle() }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                sceneChanged(phase)
            }
            // Closed during a flash: the code that was read is not paired with behind the home screen.
            .onDisappear { stopFlash() }
            #if DEBUG
            .task {
                await debugOpenManual()
                await debugScanRace()
            }
            #endif
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            FailurePage(position: position, failure: failure, note: note, onRescan: rescan)
                .task(id: failure) { await lookUpLocalNetwork(after: failure) }
        } else if attempt != nil {
            WaitingPage(
                position: position, awaiting: awaiting, localNetwork: store.pairingPhase == .waitingForLocalNetwork,
                deviceName: shownDeviceName, onCancel: cancel
            )
        } else if page == .manual {
            ManualPairView(
                network: network, note: note, onPair: { pair($0) },
                onProbeFailed: { note = "连不上这台 Mac，换个方式或稍后再试。" },
                onScan: { switchTo(.scan) }
            )
        } else {
            ScanPage(
                note: note, flash: flashing, onCode: read, onManual: { switchTo(.manual) },
                onClose: onClose.map { _ in close }, control: stage, position: position,
                onSkip: onSkip.map { skip in { stopFlash(); skip() } }, skipNote: skipNote
            )
        }
    }

    /// The device name as the Mac shows it.
    private var shownDeviceName: String {
        BridgeProtocol.deviceName(deviceName)
    }

    /// An attempt is under way (here, or in the store until its `pair` has returned), or about to start (a scanned code
    /// flashing).
    private var busy: Bool {
        attempt != nil || store.isPairing || store.pairingPhase != nil || flashing
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
        retry.started(target)
        #if DEBUG
        TraceLog.pairing("pair() starts an attempt with \(target.macName)")
        #endif
        attempt = Task {
            let result = await store.pair(target, deviceName: deviceName)
            // Cancelled: the screen has moved on already.
            guard !Task.isCancelled else { return }
            attempt = nil
            switch result {
            case .paired:
                Self.log.notice("pairing ended: paired")
                retry.ended()
                // Whatever link came meanwhile was for the pairing just made.
                queuedLink = nil
                if let onPaired { onPaired() } else { onClose?() }
            case .failed(let why):
                // The case name only (public): why a retry did or did not fire, never the code, host or Mac.
                let reached = store.lastPairReachedMac
                Self.log.notice(
                    "pairing ended: \(String(describing: why), privacy: .public), reached the Mac: \(reached, privacy: .public)"
                )
                // Once the Mac had the request, the code is used up: not tried again by itself.
                let again = retry.failed(why, reachedMac: reached)
                failure = why
                takeQueuedIfIdle()
                if let again { tryAgain(again) }
            }
        }
        return true
    }

    /// 「取消」: closes the attempt's connection (the Mac withdraws its request) and goes back to the page. A link that
    /// came meanwhile is taken once the store has let go of the attempt.
    private func cancel() {
        attempt?.cancel()
        attempt = nil
        retry.ended()
        takeQueuedIfIdle()
    }

    /// The app went inactive or came back (`scenePhase`): the 本地网络 prompt makes it inactive until it is answered.
    /// Back while an unreachable failure is on the page, its attempt may be tried again (`PairingRetry`).
    private func sceneChanged(_ phase: ScenePhase) {
        if attempt != nil || failure != nil {
            let what = attempt != nil ? "an attempt under way" : "a failure on the page"
            Self.log.notice("scene \(String(describing: phase), privacy: .public) with \(what, privacy: .public)")
        }
        if let again = retry.sceneChanged(active: phase == .active) { tryAgain(again) }
    }

    /// The failed attempt again, by itself, as if the user had scanned the same code: unless its failure page has gone,
    /// or a link waits for the user's yes over it.
    private func tryAgain(_ target: PairingTarget) {
        guard failure != nil, linkToConfirm == nil else { return }
        Self.log.notice("tried again by itself: the Mac could not be reached while the app was not active")
        pair(target)
    }

    /// The Mac could not be reached: a Bonjour lookup says whether the local network is denied (the failed connection
    /// may not say so), for the failure page to show it (`LocalNetworkNotice`).
    private func lookUpLocalNetwork(after failure: PairFailure) async {
        guard failure == .unreachable, !LocalNetworkStatus.shared.denied else { return }
        _ = await network.browser.discover()
    }

    private func rescan() {
        failure = nil
        retry.ended()
        switchTo(.scan)
    }

    private func switchTo(_ next: Page) {
        stopFlash()
        note = nil
        page = next
        takeQueuedIfIdle()
    }

    /// 「返回」: back to the home screen, dropping a code that is still flashing.
    private func close() {
        stopFlash()
        onClose?()
    }

    /// Drops a scanned code that has not been paired with yet.
    private func stopFlash() {
        guard let flashTask else { return }
        flashTask.cancel()
        self.flashTask = nil
        flashing = false
        #if DEBUG
        TraceLog.pairing("the flash is cancelled")
        #endif
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
        flashTask = Task {
            try? await Task.sleep(for: Self.flash)
            // The page was left or the screen closed meanwhile: this code is not paired with.
            guard !Task.isCancelled else {
                #if DEBUG
                TraceLog.pairing("the flash ended cancelled: pair() is not called")
                #endif
                return
            }
            flashTask = nil
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
                // In the guide the step stays: there is no home screen to go back to.
                if position == nil { close() }
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

    /// `-critterPairing scan-race`: a second and a half after the scanner is up, the camera reads a pairing code, and
    /// 100 ms into the frame's green flash 「返回」 is tapped (「手动输入」 when there is no 返回). A second after that the
    /// log says whether anything is pairing: it must be nil, with no screen left to show an attempt. `scan-read` taps
    /// nothing: the flash ends in an attempt.
    private func debugScanRace() async {
        let demo = DebugLaunch.current.pairing
        guard demo == .scanRace || demo == .scanRead else { return }
        try? await Task.sleep(for: .seconds(1.5))
        TraceLog.pairing("the camera reads a pairing code")
        _ = read(PairingDemoFakes.uri.string)
        try? await Task.sleep(for: .milliseconds(100))
        let store = store
        Task {
            try? await Task.sleep(for: .seconds(1))
            TraceLog.pairing("1 s later: store.pairingPhase = \(store.pairingPhase.map { "\($0)" } ?? "nil")")
        }
        if demo == .scanRead {
            TraceLog.pairing("nothing tapped")
        } else if onClose != nil {
            TraceLog.pairing("「返回」 100 ms into the flash")
            close()
        } else {
            TraceLog.pairing("「手动输入」 100 ms into the flash")
            switchTo(.manual)
        }
    }
    #endif
}
