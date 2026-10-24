import CritterClient
import CritterKit
import SwiftUI

/// Pairing by hand (mockup "手动输入和出错", Android `ManualPane`): the Macs found on the network as one card, the
/// chosen one marked "已选", and the code in 4 + 4 cells. 「连接」 first reads the chosen Mac's certificate fingerprint
/// and asks whether it is the one the Mac shows; only then does it pair, pinned to that fingerprint.
///
/// Under the code, the line about a Mac left without being told (`LeftMacNotice`), while there is one.
///
/// The fingerprint is read in a task this page keeps: leaving the page, choosing another Mac or connecting again
/// cancels it, and an answer that comes after that is dropped (it never shows on another page).
struct ManualPairView: View {
    let network: PairingNetwork
    /// Why the last try did not work (from the pairing screen).
    let note: String?
    let onPair: (PairingTarget) -> Void
    let onProbeFailed: () -> Void
    let onScan: () -> Void

    /// A Mac whose fingerprint was read, waiting for the user's trust.
    private struct Trust {
        let mac: DiscoveredMac
        let fingerprint: String
    }

    @State private var macs: [DiscoveredMac] = []
    @State private var selected: DiscoveredMac?
    @State private var code = ""
    /// Reading the chosen Mac's fingerprint.
    @State private var probe: Task<Void, Never>?
    @State private var trust: Trust?
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                PixelIconButton(icon: .back, label: "返回", action: onScan)
                Text("手动输入")
                    .font(.nunito(size: 18, weight: .black))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    FieldLabel(text: "局域网里的 Mac")
                    macList
                    FieldLabel(text: "Mac 上显示的 \(PairingCode.length) 位码")
                        .padding(.top, 8)
                    CodeCells(code: $code, focused: $typing, error: note != nil)
                    if let note {
                        ErrorNote(text: note)
                            .padding(.top, 4)
                    }
                    // A Mac left without being told may still push here: on every page of the pairing screen.
                    LeftMacNotice(inset: 0, above: 4)
                }
                .padding(.top, 22)
                .padding(.bottom, 16)
            }
            .refreshable { await search() }
            VStack(spacing: 8) {
                PixelButton(
                    title: probe != nil ? "正在连接…" : "连接", size: .large, wide: true, action: connect
                )
                .disabled(selected == nil || code.count != PairingCode.length || probe != nil)
                PixelButton(title: "改用扫码", style: .text, icon: .qr, action: onScan)
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 18)
        .background(Theme.bg)
        // On entering, and again whenever the list is empty (a refresh can empty it).
        .task(id: macs.isEmpty) {
            if macs.isEmpty { await searchUntilFound() }
        }
        .onChange(of: selected?.name) { stopProbing() }
        .onDisappear { stopProbing() }
        .overlay {
            if let trust { trustDialog(trust) }
        }
        #if DEBUG
        .task { await debugFill() }
        #endif
    }

    // MARK: - The Macs

    private var macList: some View {
        VStack(spacing: 0) {
            if macs.isEmpty {
                HStack(spacing: 12) {
                    PixelIconView(.laptop, cell: 3)
                        .foregroundStyle(Theme.ink3)
                    Text("正在寻找…")
                        .font(.nunito(size: 14, weight: .bold))
                        .foregroundStyle(Theme.ink2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(minHeight: 52)
            }
            ForEach(Array(macs.enumerated()), id: \.element.name) { index, mac in
                if index > 0 { Theme.line.frame(height: 1) }
                macRow(mac)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
        .pixelSurface(fill: Theme.surface, lip: Theme.shade, step: 4, lipHeight: 4)
    }

    private func macRow(_ mac: DiscoveredMac) -> some View {
        let chosen = selected?.name == mac.name
        return Button { selected = mac } label: {
            HStack(spacing: 12) {
                PixelIconView(.laptop, cell: 3)
                    .foregroundStyle(chosen ? Theme.brand : Theme.ink3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: mac.name)
                        .font(.nunito(size: 15, weight: .heavy))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(verbatim: hostAndPort(mac.endpoint.host, mac.endpoint.port))
                        .font(.nunito(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                }
                Spacer(minLength: 0)
                if chosen { ChosenChip() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// Looks for Macs until one is found (meanwhile the list says "正在寻找…"); pulling the list down looks again.
    private func searchUntilFound() async {
        while !Task.isCancelled, macs.isEmpty {
            await search()
        }
    }

    private func search() async {
        let found = await network.browser.discover()
        guard !Task.isCancelled else { return }
        macs = found
        // The chosen Mac at the address it has now, if it is still there.
        selected = selected.flatMap { chosen in found.first { $0.name == chosen.name } }
    }

    // MARK: - Connecting

    private func connect() {
        guard let mac = selected else { return }
        typing = false
        stopProbing()
        let probeMac = network.probe
        probe = Task {
            let fingerprint = await probeMac(mac.endpoint)
            // Left the page, chose another Mac or connected again meanwhile: this answer is not wanted any more.
            guard !Task.isCancelled else { return }
            probe = nil
            if let fingerprint {
                trust = Trust(mac: mac, fingerprint: fingerprint)
            } else {
                onProbeFailed()
            }
        }
    }

    private func stopProbing() {
        probe?.cancel()
        probe = nil
    }

    private func trustDialog(_ trust: Trust) -> some View {
        PixelDialog(
            title: "信任这台 Mac？", confirm: "信任并配对",
            onConfirm: {
                self.trust = nil
                onPair(PairingTarget(
                    endpoint: trust.mac.endpoint, fingerprint: trust.fingerprint, code: code, macName: trust.mac.name
                ))
            },
            onDismiss: { self.trust = nil }
        ) {
            Text(verbatim: "第一次连接「\(trust.mac.name)」。只有下面的证书指纹和 Mac 上「添加手机」里码下面显示的一致时才继续：")
            Text(verbatim: PairingURI.fingerprintPrefix(trust.fingerprint))
                .font(.system(size: 16, design: .monospaced))
                .foregroundStyle(Theme.ink)
        }
    }

    #if DEBUG
    /// `-critterPairing manual…`: the code typed, the first Mac chosen once found, and for `manual-trust` and
    /// `manual-probe-failed` 「连接」 tapped a second later.
    private func debugFill() async {
        guard case .manual(let demo)? = DebugLaunch.current.pairing else { return }
        code = PairingDemoFakes.code
        guard demo != .searching else { return }
        while macs.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
        }
        selected = macs.first
        guard demo == .trust || demo == .probeFailed else { return }
        try? await Task.sleep(for: .seconds(1))
        if !Task.isCancelled { connect() }
    }
    #endif
}

private struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.nunito(size: 12, weight: .heavy))
            .foregroundStyle(Theme.ink2)
    }
}

/// "已选" on the chosen Mac: a small brand chip with a check.
private struct ChosenChip: View {
    var body: some View {
        HStack(spacing: 4) {
            PixelIconView(.check)
            Text("已选")
                .font(.nunito(size: 11.5, weight: .black))
        }
        .foregroundStyle(Theme.brand)
        .padding(.horizontal, 7)
        .frame(minHeight: 20)
        .padding(.bottom, 2)
        .pixelSurface(fill: Theme.brandSoft, lip: Theme.brand.opacity(0.18), step: 2, lipHeight: 2)
        .fixedSize()
    }
}

/// The code as eight cells in two groups of four, like the Mac shows it. A text field behind them takes the typing
/// (only characters of `PairingCode.alphabet`, lower case made upper); the cell the next character goes into has a
/// brand edge while it has the keyboard, and every cell a pale red one after a failure.
private struct CodeCells: View {
    @Binding var code: String
    var focused: FocusState<Bool>.Binding
    let error: Bool

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .focused(focused)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(maxWidth: .infinity, minHeight: 48)
                .accessibilityLabel(Text(verbatim: "Mac 上显示的 \(PairingCode.length) 位码"))
            HStack(spacing: 5) {
                ForEach(0..<PairingCode.length, id: \.self) { index in
                    if index == PairingCode.length / 2 { Spacer().frame(width: 10) }
                    cell(index)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused.wrappedValue = true }
        .onChange(of: code) { _, typed in
            let kept = Self.kept(typed)
            if kept != typed { code = kept }
        }
    }

    private func cell(_ index: Int) -> some View {
        let characters = Array(code)
        let active = focused.wrappedValue && index == characters.count
        let edge: Color? = active ? Theme.brand : error ? Theme.errBg : nil
        return Text(verbatim: index < characters.count ? String(characters[index]) : " ")
            .font(.silkscreen(size: 24))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .padding(.bottom, 4)
            .pixelSurface(fill: Theme.surface, lip: Theme.shade, step: 3, lipHeight: 4, outline: edge, outlineWidth: 2)
    }

    /// What may be typed: upper case, characters of the code alphabet, at most a code's length.
    static func kept(_ typed: String) -> String {
        String(typed.uppercased().filter { PairingCode.alphabet.contains($0) }.prefix(PairingCode.length))
    }
}
