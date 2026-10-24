import CritterClient
import CritterKit
import SwiftUI

/// Why the answer did not get through, in red over the buttons; the card stays open. Also "未连接，连上后才能作答"
/// and "正在提交…" (`tone`), in the same type.
struct FailureLine: View {
    let text: String?
    var tone: Color = Theme.err

    var body: some View {
        if let text {
            Text(verbatim: text)
                .font(.nunito(size: 13, weight: .heavy))
                .foregroundStyle(tone)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// "✓ 已允许" (Android `DoneButton`): the large primary button turns green in three jumps (180 ms, the Critter's
/// beat), or a 150 ms fade under reduce motion. It takes no more taps.
struct DoneButton: View {
    let label: String

    @Environment(\.reduceMotion) private var reduceMotion
    @State private var turned = false

    /// Ink on the solid green, the same in both themes.
    private static let inkOnDone = Color(rgb: 0x2A2140)

    var body: some View {
        let fg = turned ? Self.inkOnDone : Theme.onBrand
        HStack(spacing: 8) {
            PixelIconView(.check)
            Text(verbatim: label)
                .font(.nunito(size: 16, weight: .black))
                .tracking(0.32)
                .lineLimit(1)
        }
        .foregroundStyle(fg)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .padding(.bottom, 4)
        .pixelSurface(
            fill: turned ? Theme.doneGlyph : Theme.brand, lip: turned ? Theme.done : Theme.brandDeep, step: 3,
            lipHeight: 4, highlight: Color.white.opacity(0.45)
        )
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .stepped(0.18, steps: 3), value: turned)
        .onAppear { turned = true }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The card's large primary button, or the green `DoneButton` in its place once `doneLabel` is set.
struct PrimaryAnswerButton: View {
    let title: String
    let doneLabel: String?
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        if let doneLabel {
            DoneButton(label: doneLabel)
        } else {
            PixelButton(title: title, size: .large, wide: true, action: action)
                .disabled(!enabled)
        }
    }
}

/// A question's topic ("缓存"): a small brand-tinted tag (Android `TopicChip`).
struct TopicChip: View {
    let text: String

    var body: some View {
        CappedWidth(max: 120) {
            Text(verbatim: text)
                .font(.nunito(size: 11.5, weight: .black))
                .foregroundStyle(Theme.brand)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .frame(minHeight: 20)
                .padding(.bottom, 2)
                .pixelSurface(fill: Theme.brandSoft, lip: Theme.brand.opacity(0.18), step: 2, lipHeight: 2)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// "电脑上也能答，谁先答算谁的", under every answer card.
struct AnswerFooter: View {
    var body: some View {
        HStack(spacing: 6) {
            PixelIconView(.laptop)
            Text("电脑上也能答，谁先答算谁的")
                .font(.nunito(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(Theme.ink2)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Nothing is left to answer (Android `HandledElsewhereCard`): answered on the Mac first, which is not an error, so
/// the Critter is in bloom (done) and the words are plain; or too late, or answered from this phone already. 「好的」
/// closes the card (it also closes by itself).
struct SettledCard: View {
    let title: String
    let text: String?
    let manifest: SkinManifest
    /// Good news: the Critter in bloom; otherwise it just stands there.
    var bloom = true

    @Environment(\.closeSheet) private var closeSheet

    var body: some View {
        VStack(spacing: 10) {
            LonePet(skin: manifest, state: bloom ? .done : .idle, cell: 5, groundInset: 24)
                .frame(height: 150)
                .clipShape(PixelShape(step: 5))
            Text(verbatim: title)
                .font(.nunito(size: 19, weight: .black))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            if let text {
                Text(verbatim: text)
                    .font(.nunito(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .multilineTextAlignment(.center)
            }
            PixelButton(title: "好的", style: .secondary, wide: true) { closeSheet() }
                .frame(width: 140)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .accessibilityElement(children: .contain)
    }
}
