import SwiftUI

/// A question over the page in the pixel material (Android `PixelDialog`): the `title`, the `content` (body text in
/// ink2 unless it says otherwise), then `dismiss` and `confirm` side by side, the confirm button a little wider. When
/// the text is too large for the screen, the content scrolls between the title and the buttons, which always stay in
/// view: the card is never taller than the room it has (no `fixedSize`).
struct PixelDialog<Content: View>: View {
    let title: String
    let confirm: String
    var dismiss = "取消"
    /// The confirm button in the error red (「取消配对」).
    var destructive = false
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    @ViewBuilder let content: Content

    /// How tall the content is laid out at full height; the scroll view is no taller than that.
    @State private var contentHeight: CGFloat = 0

    /// The body text: 14 pt on a 21 pt line.
    private static var bodySize: CGFloat { 14 }

    var body: some View {
        ZStack {
            Theme.scrim
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 14) {
                Text(verbatim: title)
                    .font(.nunito(size: 18, weight: .black))
                    .lineSpacing(25 - 18 * 1.36)
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) { content }
                        .font(.nunito(size: Self.bodySize, weight: .semibold))
                        .lineSpacing(21 - Self.bodySize * 1.36)
                        .foregroundStyle(Theme.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(maxHeight: max(contentHeight, 1))
                .scrollBounceBehavior(.basedOnSize)
                .layoutPriority(-1)
                WeightedRow(weights: [1, 1.4], spacing: 8) {
                    PixelButton(title: dismiss, style: .secondary, wide: true, action: onDismiss)
                    PixelButton(
                        title: confirm, role: destructive ? .destructive : nil,
                        style: destructive ? .secondary : .primary, wide: true, action: onConfirm
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 22)
            .pixelSurface(fill: Theme.surface, lip: Theme.shade, step: 5, lipHeight: 4)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }
}
