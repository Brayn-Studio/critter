import SwiftUI
import UIKit

/// A command or path as the terminal shows it: monospaced after a `›`, on a recessed slip.
///
/// On a list row it is cut off after eight lines. On the answer card (`scrolls`) all of it can be read: it is as
/// tall as its text, up to eight lines, and scrolls beyond that.
struct CommandSlip: View {
    let command: String
    /// Whether the slip holds all of the text and scrolls (the card), instead of cutting it off (a list row).
    var scrolls = false

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var contentHeight: CGFloat = 0

    private static let maxLines = 8
    private static let padding: CGFloat = 10

    var body: some View {
        Group {
            if scrolls {
                ScrollView {
                    text
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: SlipHeightKey.self, value: proxy.size.height)
                            }
                        }
                }
                .frame(height: min(contentHeight, maxHeight))
                .onPreferenceChange(SlipHeightKey.self) { contentHeight = $0 }
            } else {
                text
                    .lineLimit(Self.maxLines)
            }
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(Text(verbatim: command))
    }

    private var text: some View {
        Text(slipText)
            .font(.system(.footnote, design: .monospaced))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Eight lines of the slip's font, at the text size in use.
    private var maxHeight: CGFloat {
        _ = typeSize
        let footnote = UIFont.preferredFont(forTextStyle: .footnote)
        return UIFont.monospacedSystemFont(ofSize: footnote.pointSize, weight: .regular).lineHeight * CGFloat(Self.maxLines)
    }

    private var slipText: AttributedString {
        var prompt = AttributedString("› ")
        prompt.foregroundColor = .secondary
        return prompt + AttributedString(command)
    }
}

private struct SlipHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
