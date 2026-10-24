import CritterClient
import CritterKit
import SwiftUI

/// An attempt under way (mockup "等 Mac 点允许", Android `WaitingPane`): Sprig waiting with its hand up on a patch of
/// meadow, over a drawing of the row the Mac's "添加手机" window shows now with 「允许」 circled. Reaching the Mac and
/// waiting for 「允许」 are the same page; only the row's status line changes.
struct WaitingPage: View {
    /// The seeds over it, in the first-run guide.
    var position: StepPosition?
    /// The request is with the Mac (rather than still reaching it).
    let awaiting: Bool
    /// This phone's name, as the Mac shows it.
    let deviceName: String
    /// 「取消」: closes the attempt's connection (the Mac withdraws its request).
    let onCancel: () -> Void

    var body: some View {
        StepColumn(position: position) {
            StepStage(state: .waiting)
            StepTitle(text: "在 Mac 上点「允许」")
                .padding(.top, 14)
            StepBody(text: "Mac 的「添加手机」窗口里出现了下面这一行。点允许之后，这里会自己往下走。")
            MacRequestRow(deviceName: deviceName, awaiting: awaiting)
                .padding(.top, 6)
        } bottom: {
            PixelButton(title: "取消", style: .text, action: onCancel)
        }
    }
}

/// How the attempt failed: Sprig wilted on its patch of meadow, the reason on a red card under it (`PairFailure.text`,
/// one per reason), and under that why a link that came meanwhile was not used (`note`). 「重新扫码」 goes back to
/// the scanner.
struct FailurePage: View {
    /// The seeds over it, in the first-run guide.
    var position: StepPosition?
    let failure: PairFailure
    let note: String?
    let onRescan: () -> Void

    var body: some View {
        StepColumn(position: position) {
            StepStage(state: .error)
            ErrorNote(text: failure.text, pet: false, size: 14.5)
                .padding(.top, 14)
            if let note {
                ErrorNote(text: note, pet: false)
            }
        } bottom: {
            PixelButton(title: "重新扫码", size: .large, icon: .qr, wide: true, action: onRescan)
        }
    }
}

/// A pairing page's frame (Android `StepPage`): the seeds on top in the first-run guide (`position`), `content` from
/// the top, scrolling when the type is large, and the `bottom` buttons held at the bottom; 24 pt side margins.
struct StepColumn<Content: View, Bottom: View>: View {
    var position: StepPosition?
    @ViewBuilder let content: Content
    @ViewBuilder let bottom: Bottom

    var body: some View {
        VStack(spacing: 0) {
            if let position {
                SeedRow(position: position)
                    .padding(.top, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) { content }
                    .padding(.top, 12)
                    .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 8) { bottom }
                .padding(.bottom, 16)
        }
        .padding(.horizontal, stepGutter)
        .background(Theme.bg)
    }
}

/// A drawing of the Mac's request row: the phone's name, where the attempt is, and the Mac's two buttons, which are
/// pictures, not buttons.
private struct MacRequestRow: View {
    let deviceName: String
    let awaiting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                PixelIconView(.laptop, cell: 3)
                    .foregroundStyle(Theme.brand)
                Text(verbatim: "「\(deviceName)」请求连接")
                    .font(.nunito(size: 14.5, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
            }
            Text(awaiting ? "在 Mac 上点「允许」" : "连接中…")
                .font(.nunito(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.ink2)
            WeightedRow(weights: [1, 1.4], spacing: 8) {
                PictureButton(title: "拒绝", primary: false)
                PictureButton(title: "允许", primary: true)
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelSurface(fill: Theme.surface, lip: Theme.shade, step: 5, lipHeight: 4)
        .accessibilityElement(children: .combine)
    }
}

/// A small button as the Mac draws it; the primary one has the orange dashed ring around it, 2 pt out (the mockup's
/// `outline: 3px dashed; outline-offset: 2px`).
private struct PictureButton: View {
    let title: String
    let primary: Bool

    var body: some View {
        Text(verbatim: title)
            .font(.nunito(size: 13.5, weight: .black))
            .foregroundStyle(primary ? Theme.onBrand : Theme.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 31)
            .padding(.bottom, 3)
            .pixelSurface(
                fill: primary ? Theme.brand : Theme.surface2, lip: primary ? Theme.brandDeep : Theme.shade, step: 3,
                lipHeight: 3, highlight: primary ? Color.white.opacity(0.45) : nil
            )
            .overlay {
                if primary {
                    DashedRing(thickness: 3, dash: 6, gap: 4)
                        .fill(Theme.wait)
                        .padding(-5)
                }
            }
    }
}

/// Dashes of `thickness` along the edges of the rect, `dash` long and `gap` apart, square-ended.
private struct DashedRing: Shape {
    let thickness: CGFloat
    let dash: CGFloat
    let gap: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let t = thickness
        var x: CGFloat = 0
        while x < rect.width {
            let w = min(dash, rect.width - x)
            path.addRect(CGRect(x: rect.minX + x, y: rect.minY, width: w, height: t))
            path.addRect(CGRect(x: rect.minX + x, y: rect.maxY - t, width: w, height: t))
            x += dash + gap
        }
        var y: CGFloat = 0
        while y < rect.height {
            let h = min(dash, rect.height - y)
            path.addRect(CGRect(x: rect.minX, y: rect.minY + y, width: t, height: h))
            path.addRect(CGRect(x: rect.maxX - t, y: rect.minY + y, width: t, height: h))
            y += dash + gap
        }
        return path
    }
}
