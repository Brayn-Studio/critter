import CritterClient
import CritterKit
import SwiftUI

/// Pairing (Android `PairingScreen`): scan the QR code the Mac shows, open its `critter-pair://` link (shown in a
/// confirmation first, with the Mac's name, address and fingerprint), or pick the Mac from the network and type the
/// code. Only Macs on the local network are paired with (`PrivateNetwork`, the ranges the Mac itself serves).
///
/// One attempt at a time: while one is under way (`store.pairingPhase` set), nothing starts another. The screen then
/// shows where it is, and how it failed if it did; when it succeeds the root view shows the home screen.
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
    /// How the last attempt failed.
    @State private var failure: PairFailure?
    @State private var linkToConfirm: PairingURI?

    var body: some View {
        Group {
            if let failure {
                PairingProgressView(step: .failed(failure), deviceName: shownDeviceName, onCancel: {}, onRescan: rescan)
            } else if attempt != nil {
                PairingProgressView(
                    step: store.pairingPhase == .awaitingApproval ? .awaitingApproval : .connecting,
                    deviceName: shownDeviceName, onCancel: cancel, onRescan: {}
                )
            } else if page == .manual {
                ManualPairView(
                    note: note, onPair: { pair($0) },
                    onProbeFailed: { note = "连不上这台 Mac，换个方式或稍后再试。" },
                    onScan: { switchTo(.scan) }
                )
            } else {
                scanPage
            }
        }
        .overlay {
            if let uri = linkToConfirm { linkConfirmation(uri) }
        }
        .onChange(of: link, initial: true) { _, incoming in
            take(incoming)
        }
    }

    /// The device name as the Mac shows it.
    private var shownDeviceName: String {
        BridgeProtocol.deviceName(deviceName)
    }

    // MARK: - Pairing

    /// Starts pairing with `target`, unless an attempt is under way or the Mac is not on the local network.
    /// Returns whether it started.
    @discardableResult
    private func pair(_ target: PairingTarget) -> Bool {
        guard attempt == nil, store.pairingPhase == nil else { return false }
        guard PrivateNetwork.isAllowed(host: target.endpoint.host) else {
            note = "地址 \(target.endpoint.host) 不在局域网里。Critter 只和同一个局域网里的 Mac 配对。"
            return false
        }
        note = nil
        failure = nil
        attempt = Task {
            let result = await store.pair(target, deviceName: deviceName)
            // Cancelled: the screen has moved on already.
            guard !Task.isCancelled else { return }
            attempt = nil
            switch result {
            case .paired: onClose?()
            case .failed(let why): failure = why
            }
        }
        return true
    }

    /// 「取消」: closes the attempt's connection (the Mac withdraws its request) and goes back to the page.
    private func cancel() {
        attempt?.cancel()
        attempt = nil
    }

    private func rescan() {
        failure = nil
        switchTo(.scan)
    }

    private func switchTo(_ next: Page) {
        note = nil
        page = next
    }

    /// A QR code the camera read. Returns whether to keep scanning: not once a pairing code has been taken.
    private func read(_ text: String) -> Bool {
        guard attempt == nil, store.pairingPhase == nil, linkToConfirm == nil else { return true }
        guard let uri = PairingURI(string: text) else {
            note = "这不是 Critter 的配对二维码。"
            return true
        }
        return !pair(PairingTarget(uri: uri))
    }

    /// A link the app was opened with: confirmed first (unless it comes from `-critterPairURI`), ignored while an
    /// attempt is under way, refused if the Mac is not on the local network.
    private func take(_ incoming: IncomingPairLink?) {
        guard let incoming else { return }
        link = nil
        linkToConfirm = nil
        guard attempt == nil, store.pairingPhase == nil else { return }
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

    // MARK: - Pages

    private var scanPage: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    Text("扫 Mac 上的二维码")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Viewfinder(onCode: read)
                    Text("在 Mac 上打开 Critter 的「设置…」，打开「允许手机连接」，点「添加手机…」，把出现的二维码放进框里。")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    if let note { PairingNote(text: note) }
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 16)
            }
            VStack(spacing: 8) {
                Button { switchTo(.manual) } label: {
                    Label("手动输入", systemImage: "keyboard").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                if let onClose {
                    Button("返回", action: onClose)
                        .controlSize(.large)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    private func linkConfirmation(_ uri: PairingURI) -> some View {
        PairingDialog(
            title: "和这台 Mac 配对？", confirm: "配对",
            onConfirm: {
                linkToConfirm = nil
                pair(PairingTarget(uri: uri))
            },
            onCancel: {
                linkToConfirm = nil
                onClose?()
            }
        ) {
            Text(verbatim: "一个链接要让这台手机和「\(Theme.macName(uri.name))」配对。只在你刚在 Mac 上点了「添加手机」时才继续。")
            Text(verbatim: "地址  \(hostAndPort(uri.host, uri.port))")
                .font(.footnote)
            Text(verbatim: "证书指纹  \(PairingURI.fingerprintPrefix(uri.fingerprint))")
                .font(.body.monospaced())
            Text("和 Mac 上「添加手机」里码下面的指纹一致时才配对。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let existing = store.pairing {
                Text(verbatim: "这会替换现在和「\(Theme.macName(existing.macName))」的配对。")
                    .fontWeight(.bold)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// The square the camera shows through, or why there is no camera here.
private struct Viewfinder: View {
    let onCode: @MainActor (String) -> Bool
    /// nil while it is being found out (and the camera asked for).
    @State private var canScan: Bool?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        ZStack {
            shape.fill(Color(.secondarySystemBackground))
            switch canScan {
            case true?:
                QRScannerView(onCode: onCode).clipShape(shape)
            case false?:
                Text("这台设备不能扫码，可以用系统相机扫，或者手动输入")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(24)
            case nil:
                ProgressView()
            }
            shape.strokeBorder(Color.primary.opacity(0.7), lineWidth: 3)
        }
        .frame(width: 248, height: 248)
        .task { canScan = await QRScannerView.canScan() }
    }
}

/// A question over the pairing screen (Android `PixelDialog`): a title, what to check, 「取消」 and a yes.
struct PairingDialog<Content: View>: View {
    let title: String
    let confirm: String
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: title)
                    .font(.title3.bold())
                content
                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Text("取消").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button(action: onConfirm) {
                        Text(verbatim: confirm).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                .padding(.top, 8)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(20)
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 24)
            .accessibilityAddTraits(.isModal)
        }
    }
}

/// Why something did not work, in red (Android `ErrorNote`); read out when it appears.
struct PairingNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .accessibilityHidden(true)
            Text(verbatim: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.red)
        .padding(12)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .onChange(of: text, initial: true) { _, text in
            AccessibilityNotification.Announcement(text).post()
        }
    }
}

/// `host:port`, an IPv6 host in brackets.
func hostAndPort(_ host: String, _ port: UInt16) -> String {
    host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
}
