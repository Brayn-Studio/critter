import SwiftUI

/// A command or path as the terminal shows it: monospaced after a `›`, on a recessed slip.
struct CommandSlip: View {
    let command: String
    /// How many lines show before the text is cut off; nil shows all of it.
    var lineLimit: Int? = 8

    var body: some View {
        Text(slipText)
            .font(.system(.footnote, design: .monospaced))
            .lineLimit(lineLimit)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel(Text(verbatim: command))
    }

    private var slipText: AttributedString {
        var prompt = AttributedString("› ")
        prompt.foregroundColor = .secondary
        return prompt + AttributedString(command)
    }
}
