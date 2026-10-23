import CritterClient
import SwiftUI

/// A pairing attempt: reaching the Mac, waiting for 「允许」 there (over a drawing of the row the Mac's "添加手机"
/// window shows now), or how it failed.
struct PairingProgressView: View {
    enum Step: Equatable {
        case connecting
        case awaitingApproval
        case failed(PairFailure)
    }

    let step: Step
    /// This phone's name, as the Mac shows it.
    let deviceName: String
    /// 「取消」, while under way.
    let onCancel: () -> Void
    /// 「重新扫码」, once failed.
    let onRescan: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            content
            Spacer(minLength: 24)
            if case .failed = step {
                Button(action: onRescan) {
                    Label("重新扫码", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button("取消", action: onCancel)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .connecting:
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("连接中…")
                    .font(.title3.weight(.semibold))
            }
        case .awaitingApproval:
            VStack(spacing: 16) {
                Text("在 Mac 上点「允许」")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Mac 的「添加手机」窗口里出现了下面这一行。点允许之后，这里会自己往下走。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                MacRequestRow(deviceName: deviceName)
                    .padding(.top, 8)
            }
        case .failed(let why):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text(verbatim: why.text)
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// A drawing of the Mac's request row; its buttons are pictures, not buttons.
private struct MacRequestRow: View {
    let deviceName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer")
                    .foregroundStyle(Color.accentColor)
                Text(verbatim: "「\(deviceName)」请求连接")
                    .font(.subheadline.weight(.bold))
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                picture("拒绝", primary: false)
                picture("允许", primary: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "「\(deviceName)」请求连接"))
    }

    /// The Mac's button; 「允许」 has a dashed ring around it.
    private func picture(_ title: String, primary: Bool) -> some View {
        Text(verbatim: title)
            .font(.subheadline.weight(.heavy))
            .foregroundStyle(primary ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(
                primary ? Color.accentColor : Color(.tertiarySystemFill),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                if primary {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .inset(by: -4)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
            }
    }
}
