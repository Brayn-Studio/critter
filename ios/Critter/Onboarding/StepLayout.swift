import CritterClient
import SwiftUI

// The look every step of the first-run guide shares (the mockups' "首次引导与配对", Android `StepLayout`): the seeds,
// a little picture, a big title, one sentence, then at the bottom the main button, 「跳过」 and what skipping costs.
// The pairing pages (`StepColumn`, `StepTitle`, `StepBody`, `StepStage`) are the same frame.

/// What skipping costs, in small centred type under the skip button (Android `SkipNote`, the mockups' `.skipnote`).
struct SkipNote: View {
    let text: String
    var color: Color = Theme.ink2

    var body: some View {
        Text(verbatim: text)
            .font(.nunito(size: 12, weight: .semibold))
            .lineSpacing(12 * (1.5 - 1.36))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

/// One step (Android `StepPage`): the seeds (when `position` is given), the `illustration`, the title, the sentence and
/// `extra`, all of which scroll when the type is large; then at the bottom the `primary` button, a `ghost` one (skip,
/// or another way out) and its `note`. Once `done` it says "已完成" under the sentence and drops the ghost button and
/// the note.
struct StepPage<Illustration: View, Extra: View>: View {
    let position: StepPosition?
    let title: String
    let text: String
    var primary: String?
    var onPrimary: () -> Void
    var ghost: String?
    var onGhost: () -> Void
    var note: String?
    var done: Bool
    let extra: Extra
    let illustration: Illustration

    init(
        position: StepPosition?, title: String, text: String,
        primary: String? = nil, onPrimary: @escaping () -> Void = {},
        ghost: String? = nil, onGhost: @escaping () -> Void = {}, note: String? = nil, done: Bool = false,
        @ViewBuilder extra: () -> Extra, @ViewBuilder illustration: () -> Illustration
    ) {
        self.position = position
        self.title = title
        self.text = text
        self.primary = primary
        self.onPrimary = onPrimary
        self.ghost = ghost
        self.onGhost = onGhost
        self.note = note
        self.done = done
        self.extra = extra()
        self.illustration = illustration()
    }

    var body: some View {
        StepColumn(position: position) {
            illustration
            StepTitle(text: title)
                .padding(.top, 14)
            StepBody(text: text)
            if done {
                HStack(spacing: 6) {
                    PixelIconView(.check)
                    Text("已完成")
                        .font(.nunito(size: 14, weight: .heavy))
                }
                .foregroundStyle(Theme.done)
                .accessibilityElement(children: .combine)
            }
            extra
        } bottom: {
            if let primary {
                PixelButton(title: primary, size: .large, wide: true, action: onPrimary)
            }
            if !done, let ghost {
                PixelButton(title: ghost, style: .text, action: onGhost)
            }
            if !done, let note {
                SkipNote(text: note)
            }
        }
    }
}

extension StepPage where Extra == EmptyView {
    init(
        position: StepPosition?, title: String, text: String,
        primary: String? = nil, onPrimary: @escaping () -> Void = {},
        ghost: String? = nil, onGhost: @escaping () -> Void = {}, note: String? = nil, done: Bool = false,
        @ViewBuilder illustration: () -> Illustration
    ) {
        self.init(
            position: position, title: title, text: text, primary: primary, onPrimary: onPrimary, ghost: ghost,
            onGhost: onGhost, note: note, done: done, extra: { EmptyView() }, illustration: illustration
        )
    }
}

/// A numbered step of something to do elsewhere (the mockups' "保持后台运行" cards, Android `KeepAliveCard`): the number
/// on a little square, a title and what to tap, on a raised card.
struct NumberedStepCard: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.silkscreen(size: 15))
                .foregroundStyle(Theme.brand)
                .frame(width: 26, height: 26)
                .background(Theme.brandSoft)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.nunito(size: 15, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text(verbatim: detail)
                    .font(.nunito(size: 12.5, weight: .semibold))
                    .lineSpacing(12.5 * (1.44 - 1.36))
                    .foregroundStyle(Theme.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .pixelSurface(fill: Theme.surface, lip: Theme.shade, step: 4, lipHeight: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "第 \(number) 步，\(title)，\(detail)"))
    }
}
