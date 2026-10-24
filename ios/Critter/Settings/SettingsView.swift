import CritterClient
import SwiftUI

/// The settings (Android `SettingsScreen`): for now only the connection, the Mac and how it is, and the two ways to
/// leave it.
struct SettingsView: View {
    let store: BridgeStore
    /// 「重新配对」: the pairing screen over the home screen; the pairing stays until the new one has succeeded.
    let onPairAgain: () -> Void

    @State private var confirmingUnpair = false

    private var macName: String {
        Theme.macName(store.pairing?.macName)
    }

    var body: some View {
        Form {
            Section("连接") {
                LabeledContent("已配对的 Mac") {
                    Text(verbatim: macName)
                }
                LabeledContent("状态") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(tint)
                            .frame(width: 8, height: 8)
                        Text(verbatim: SessionText.conn(store.conn))
                            .multilineTextAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
                Button("重新配对", action: onPairAgain)
                Button("取消配对", role: .destructive) { confirmingUnpair = true }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .alert(Text(verbatim: "取消和 \(macName) 的配对？"), isPresented: $confirmingUnpair) {
            Button("保留", role: .cancel) {}
            Button("取消配对", role: .destructive) { store.unpair() }
        } message: {
            Text("手机会断开。之后要用，得在 Mac 上重新「添加手机」再扫码。")
        }
    }

    private var tint: Color {
        Theme.conn(store.conn).dot
    }
}
