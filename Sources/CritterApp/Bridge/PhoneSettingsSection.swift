import AppKit
import CoreImage.CIFilterBuiltins
import CritterCore
import SwiftUI

/// What the "手机" section of the settings window shows and does (spec §6.6): the paired
/// phones, the pairing sheet, the status-line hook-up and "重置配对". The bridge itself lives
/// on its own queue; this only reads what `BridgeController` publishes and asks it to act.
@MainActor
@Observable
final class PhoneSettingsModel {
    /// A pairing code on show: the QR code's URI, and when it stops working (issue time plus
    /// `PairingCode.lifetimeMs`, spec R3).
    struct PairingOffer: Equatable {
        var uri: PairingURI
        var expiresAt: Date

        var spacedCode: String {
            let code = uri.code
            return code.count == 8 ? "\(code.prefix(4)) \(code.dropFirst(4))" : code
        }
    }

    /// A phone waiting to be let in. Never a modal alert: the pet must stay draggable.
    struct PairRequest {
        var deviceName: String
        var answer: (Bool) -> Void
    }

    private(set) var devices: [DeviceRecord] = []
    private(set) var statusLine: StatusLineInstaller.Status?
    private(set) var statusLineBusy = false
    private(set) var statusLineNote: String?
    private(set) var hookInstalled = true
    /// The offer in the sheet; nil before the first one and while one is being made.
    private(set) var offer: PairingOffer?
    private(set) var offerFailed = false
    private(set) var makingOffer = false
    private(set) var pairRequest: PairRequest?
    var sheetOpen = false
    var confirmingReset = false

    @ObservationIgnored private let bridge: BridgeController
    @ObservationIgnored private let paths: CritterPaths
    @ObservationIgnored private var requestToken = 0
    @ObservationIgnored private var offerToken = 0

    init(bridge: BridgeController, paths: CritterPaths) {
        self.bridge = bridge
        self.paths = paths
    }

    private var hookPath: String { paths.binDir.appendingPathComponent("critter-hook").path }

    // MARK: - Refreshing

    func refresh() {
        devices = bridge.devices().sorted { $0.pairedAt < $1.pairedAt }
        refreshStatusLine()
    }

    private func refreshStatusLine() {
        let file = paths.claudeSettingsFile.resolvingSymlinksInPath()
        let hookPath = hookPath
        DispatchQueue.global(qos: .userInitiated).async {
            let text = (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) }
            let status = text.map { StatusLineInstaller.status(settings: $0, hookPath: hookPath) }
            let hookExists = FileManager.default.isExecutableFile(atPath: hookPath)
            DispatchQueue.main.async {
                // Safe: `DispatchQueue.main` always runs on the main thread/actor.
                MainActor.assumeIsolated {
                    self.statusLine = status
                    self.hookInstalled = hookExists
                }
            }
        }
    }

    // MARK: - Status line

    /// "接入" / "撤销", on a background queue; the same rules as `critter-hook statusline-install`
    /// (the original file is backed up first).
    func toggleStatusLine() {
        guard !statusLineBusy, let current = statusLine, current != .otherType else { return }
        let install = current == .notInstalled
        statusLineBusy = true
        statusLineNote = nil
        let paths = paths
        DispatchQueue.global(qos: .userInitiated).async {
            let result = HookCommand.runStatusLineAdmin(
                install: install, paths: paths, now: Int64(Date().timeIntervalSince1970 * 1000)
            )
            DispatchQueue.main.async {
                // Safe: `DispatchQueue.main` always runs on the main thread/actor.
                MainActor.assumeIsolated {
                    self.statusLineBusy = false
                    self.statusLineNote = result.exitCode == 0 ? nil : result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.refreshStatusLine()
                }
            }
        }
    }

    // MARK: - Pairing

    /// Opens the sheet with a fresh code.
    func addPhone() {
        sheetOpen = true
        newOffer()
    }

    /// A new code, replacing the one on show.
    func newOffer() {
        offerToken += 1
        let token = offerToken
        makingOffer = true
        offerFailed = false
        offer = nil
        bridge.beginPairing(autoApprove: false) { uri in
            DispatchQueue.main.async {
                // Safe: `DispatchQueue.main` always runs on the main thread/actor.
                MainActor.assumeIsolated {
                    guard token == self.offerToken else { return }
                    self.makingOffer = false
                    if let uri {
                        self.offer = PairingOffer(uri: uri, expiresAt: Date().addingTimeInterval(Double(PairingCode.lifetimeMs) / 1000))
                    } else {
                        self.offerFailed = true
                    }
                }
            }
        }
    }

    /// Also withdraws the code on show: once the sheet is gone, nobody is there to watch who uses it.
    func closeSheet() {
        sheetOpen = false
        bridge.cancelPairing()
        offerToken += 1
        offer = nil
        makingOffer = false
        offerFailed = false
    }

    /// `BridgeController.onPairRequest`: a phone used the code and waits for an answer. The
    /// code is spent, so the offer goes; an earlier request still waiting is declined.
    func receivePairRequest(deviceName: String, answer: @escaping (Bool) -> Void) {
        pairRequest?.answer(false)
        requestToken += 1
        let token = requestToken
        pairRequest = PairRequest(deviceName: deviceName, answer: answer)
        offer = nil
        // The bridge gives up on a phone that waits this long; so does the row.
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(PairingCode.lifetimeMs) / 1000) {
            // Safe: `DispatchQueue.main` always runs on the main thread/actor.
            MainActor.assumeIsolated {
                if self.requestToken == token { self.pairRequest = nil }
            }
        }
    }

    func resolvePairRequest(allow: Bool) {
        guard let request = pairRequest else { return }
        pairRequest = nil
        requestToken += 1
        request.answer(allow)
        if allow {
            sheetOpen = false
            // The registry is updated on the bridge queue just after.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                // Safe: `DispatchQueue.main` always runs on the main thread/actor.
                MainActor.assumeIsolated { self.refresh() }
            }
        } else if sheetOpen {
            newOffer()
        }
    }

    // MARK: - Devices and reset

    func revoke(_ device: DeviceRecord) {
        bridge.revoke(deviceId: device.id)
        devices.removeAll { $0.id == device.id }
    }

    func resetPairing() {
        confirmingReset = false
        pairRequest?.answer(false)
        pairRequest = nil
        closeSheet()
        bridge.resetPairing()
        devices = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            // Safe: `DispatchQueue.main` always runs on the main thread/actor.
            MainActor.assumeIsolated { self.refresh() }
        }
    }
}

/// "几分钟前" style, for a device's last sign of life.
enum PhoneLastSeen {
    static func text(lastSeen: Int64?, now: Date = Date()) -> String {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        guard let lastSeen else { return "还没有连接过" }
        let seconds = max(0, (nowMs - lastSeen) / 1000)
        switch seconds {
        case ..<60: return "刚刚在线"
        case ..<3600: return "\(seconds / 60) 分钟前在线"
        case ..<86_400: return "\(seconds / 3600) 小时前在线"
        default: return "\(seconds / 86_400) 天前在线"
        }
    }
}

/// The "手机" section's rows.
struct PhoneSettingsSection: View {
    @Bindable var store: SettingsStore
    let phone: PhoneSettingsModel

    var body: some View {
        Section("手机") {
            Toggle(isOn: $store.bridgeEnabled) {
                Text("允许手机连接")
                Text("让同一 Wi-Fi 下已配对的安卓手机查看会话，并在手机上回答权限、提问和计划")
            }

            LabeledContent("已配对的手机") {
                Button("添加手机…") { phone.addPhone() }
                    .disabled(!store.bridgeEnabled)
            }

            if let request = phone.pairRequest, !phone.sheetOpen {
                PairRequestRow(request: request, phone: phone)
            }

            ForEach(phone.devices, id: \.id) { device in
                LabeledContent {
                    Button("撤销") { phone.revoke(device) }
                } label: {
                    Text(device.name)
                    Text(PhoneLastSeen.text(lastSeen: device.lastSeen))
                }
            }

            statusLineRow

            if phone.confirmingReset {
                LabeledContent {
                    HStack {
                        Button("取消") { phone.confirmingReset = false }
                        Button("重置", role: .destructive) { phone.resetPairing() }
                    }
                } label: {
                    Text("确定重置配对？")
                    Text("所有手机都要重新配对")
                }
            } else {
                LabeledContent("重置配对") {
                    Button("重置…") { phone.confirmingReset = true }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                phone.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .sheet(isPresented: Binding(get: { phone.sheetOpen }, set: { if !$0 { phone.closeSheet() } })) {
            PairingSheet(phone: phone)
        }
    }

    @ViewBuilder private var statusLineRow: some View {
        LabeledContent {
            if let status = phone.statusLine, status != .otherType {
                Button(status == .installed ? "撤销" : "接入") { phone.toggleStatusLine() }
                    .disabled(phone.statusLineBusy || (status == .notInstalled && !phone.hookInstalled))
            }
        } label: {
            Text("状态栏数据")
            Text(statusLineDetail)
        }
    }

    private var statusLineDetail: String {
        if let note = phone.statusLineNote { return note }
        switch phone.statusLine {
        case .installed: return "已接入"
        case .notInstalled: return phone.hookInstalled ? "未接入（手机上的上下文和额度需要它）" : "未接入（先运行 make install）"
        case .otherType: return "已被改成其它类型"
        case nil: return "读不到 ~/.claude/settings.json"
        }
    }
}

/// "「设备名」请求连接" with "拒绝" and "允许": beside each other in the form, stacked in the
/// narrow sheet (where a row would squeeze the buttons down to "…").
private struct PairRequestRow: View {
    let request: PhoneSettingsModel.PairRequest
    let phone: PhoneSettingsModel
    var stacked = false

    var body: some View {
        if stacked {
            VStack(spacing: 10) {
                Text("「\(request.deviceName)」请求连接")
                buttons
            }
        } else {
            LabeledContent {
                buttons
            } label: {
                Text("「\(request.deviceName)」请求连接")
            }
        }
    }

    private var buttons: some View {
        HStack {
            Button("拒绝") { phone.resolvePairRequest(allow: false) }
            // No default-button shortcut: a stray Return must never let a phone in.
            Button("允许") { phone.resolvePairRequest(allow: true) }
        }
        .fixedSize()
    }
}

/// The sheet behind "添加手机…": QR code, the code in 4+4, the time left, and the request row.
private struct PairingSheet: View {
    let phone: PhoneSettingsModel

    var body: some View {
        VStack(spacing: 14) {
            Text("添加手机").font(.headline)

            if let request = phone.pairRequest {
                Text("手机已扫码").foregroundStyle(.secondary)
                PairRequestRow(request: request, phone: phone, stacked: true)
            } else if let offer = phone.offer {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let left = offer.expiresAt.timeIntervalSince(timeline.date)
                    if left > 0 {
                        offerView(offer, secondsLeft: Int(left.rounded(.up)))
                    } else {
                        VStack(spacing: 10) {
                            Text("配对码已过期").foregroundStyle(.secondary)
                            Button("重新生成") { phone.newOffer() }
                        }
                        .frame(width: 220, height: 220)
                    }
                }
            } else if phone.offerFailed {
                VStack(spacing: 10) {
                    Text("现在没法配对").foregroundStyle(.secondary)
                    Text("Critter 还没有开始监听，或者这台 Mac 没有连上局域网。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试") { phone.newOffer() }
                }
                .frame(width: 260, height: 220)
            } else {
                ProgressView().frame(width: 220, height: 220)
            }

            HStack {
                Spacer()
                Button("完成") { phone.closeSheet() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func offerView(_ offer: PhoneSettingsModel.PairingOffer, secondsLeft: Int) -> some View {
        VStack(spacing: 10) {
            if let image = QRCode.image(for: offer.uri.string) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .accessibilityLabel("配对二维码")
            }
            Text(offer.spacedCode)
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
            Text("用手机上的 Critter 扫描，或输入这个码；还剩 \(secondsLeft / 60):\(String(format: "%02d", secondsLeft % 60))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

/// `CIFilter.qrCodeGenerator`, scaled up by a whole factor so the modules stay sharp.
enum QRCode {
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale: CGFloat = 8
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
