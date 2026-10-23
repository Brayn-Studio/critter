import CritterClient
import CritterKit
import SwiftUI

/// Pairing by hand (Android `ManualPane`): the Macs found on the network, the code in 4 + 4 cells. 「连接」 first
/// reads the chosen Mac's certificate fingerprint and asks whether it is the one the Mac shows; only then does it
/// pair, pinned to that fingerprint.
struct ManualPairView: View {
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
    @State private var probing = false
    @State private var trust: Trust?
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button(action: onScan) {
                    Image(systemName: "chevron.backward")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("返回")
                Text("手动输入")
                    .font(.title3.bold())
                Spacer()
            }
            .padding(.horizontal, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    FieldLabel(text: "局域网里的 Mac")
                    macList
                    FieldLabel(text: "Mac 上显示的 \(PairingCode.length) 位码")
                        .padding(.top, 8)
                    CodeCells(code: $code, focused: $typing, error: note != nil)
                    if let note {
                        PairingNote(text: note)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .padding(.bottom, 16)
            }
            .refreshable { await search() }
            VStack(spacing: 8) {
                Button(action: connect) {
                    Text(probing ? "正在连接…" : "连接").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selected == nil || code.count != PairingCode.length || probing)
                Button(action: onScan) {
                    Label("改用扫码", systemImage: "qrcode.viewfinder")
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        // On entering, and again whenever the list is empty (a refresh can empty it).
        .task(id: macs.isEmpty) {
            if macs.isEmpty { await searchUntilFound() }
        }
        .overlay {
            if let trust { trustDialog(trust) }
        }
    }

    // MARK: - The Macs

    private var macList: some View {
        VStack(spacing: 0) {
            if macs.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "laptopcomputer")
                        .foregroundStyle(.tertiary)
                    Text("正在寻找…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
            }
            ForEach(Array(macs.enumerated()), id: \.element.name) { index, mac in
                if index > 0 { Divider().padding(.leading, 16) }
                macRow(mac)
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func macRow(_ mac: DiscoveredMac) -> some View {
        let chosen = selected?.name == mac.name
        return Button { selected = mac } label: {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .foregroundStyle(chosen ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: mac.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(verbatim: hostAndPort(mac.endpoint.host, mac.endpoint.port))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if chosen {
                    Label("已选", systemImage: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
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
        let found = await BonjourBrowser().discover()
        guard !Task.isCancelled else { return }
        macs = found
        // The chosen Mac at the address it has now, if it is still there.
        selected = selected.flatMap { chosen in found.first { $0.name == chosen.name } }
    }

    // MARK: - Connecting

    private func connect() {
        guard let mac = selected else { return }
        typing = false
        probing = true
        Task {
            let fingerprint = await CertificateProbe(transport: URLSessionTransport()).fingerprint(of: mac.endpoint)
            probing = false
            if let fingerprint {
                trust = Trust(mac: mac, fingerprint: fingerprint)
            } else {
                onProbeFailed()
            }
        }
    }

    private func trustDialog(_ trust: Trust) -> some View {
        PairingDialog(
            title: "信任这台 Mac？", confirm: "信任并配对",
            onConfirm: {
                self.trust = nil
                onPair(PairingTarget(endpoint: trust.mac.endpoint, fingerprint: trust.fingerprint, code: code, macName: trust.mac.name))
            },
            onCancel: { self.trust = nil }
        ) {
            Text(verbatim: "第一次连接「\(trust.mac.name)」。只有下面的证书指纹和 Mac 上「添加手机」里码下面显示的一致时才继续：")
            Text(verbatim: PairingURI.fingerprintPrefix(trust.fingerprint))
                .font(.title3.monospaced())
        }
    }
}

private struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.footnote.weight(.bold))
            .foregroundStyle(.secondary)
    }
}

/// The code as eight cells in two groups of four, like the Mac shows it. A text field behind them takes the typing
/// (only characters of `PairingCode.alphabet`, lower case made upper); the cell the next character goes into is
/// outlined while it has the keyboard.
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
        let border: Color = active ? .accentColor : error ? .red.opacity(0.5) : .clear
        return Text(verbatim: index < characters.count ? String(characters[index]) : " ")
            .font(.system(size: 24, weight: .semibold, design: .monospaced))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(border, lineWidth: 2))
    }

    /// What may be typed: upper case, characters of the code alphabet, at most a code's length.
    static func kept(_ typed: String) -> String {
        String(typed.uppercased().filter { PairingCode.alphabet.contains($0) }.prefix(PairingCode.length))
    }
}
