import SwiftUI

/// Markdown as a plan has it: headings, lists, code, quotes and paragraphs, with bold, italics and `code` inside.
/// `AttributedString(markdown:)` reads it; `Text` shows the inline styles but not the blocks, so each block (the
/// runs that share a presentation intent) is laid out here. Text that does not parse is shown as it is.
struct MarkdownBlocks: View {
    let markdown: String

    var body: some View {
        if let blocks = Self.blocks(of: markdown) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { block in
                    view(for: block)
                }
            }
        } else {
            Text(verbatim: markdown)
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block.kind {
        case .paragraph:
            Text(block.text)
        case .heading(let level):
            Text(block.text)
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level <= 2 ? 4 : 0)
        case .item(let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: marker)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(block.text)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .code:
            Text(verbatim: String(block.text.characters).trimmingCharacters(in: .newlines))
                .font(.system(.footnote, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .quote:
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)
                Text(block.text)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Parsing

    private struct Block: Identifiable {
        enum Kind {
            case paragraph
            case heading(Int)
            case item(marker: String, depth: Int)
            case code
            case quote
        }

        let id: Int
        let kind: Kind
        var text: AttributedString
    }

    private static func blocks(of markdown: String) -> [Block]? {
        guard let parsed = try? AttributedString(markdown: markdown) else { return nil }
        var blocks: [Block] = []
        var current: Int?
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let slice = AttributedString(parsed[run.range])
            // Runs of one block follow each other, and share the identity of the block's innermost component.
            if let identity = components.first?.identity, identity == current, !blocks.isEmpty {
                blocks[blocks.count - 1].text += slice
            } else {
                blocks.append(Block(id: blocks.count, kind: kind(of: components), text: slice))
                current = components.first?.identity
            }
        }
        return blocks.filter { !$0.text.characters.isEmpty }
    }

    /// What a block is, from the intent components of its first run (innermost first).
    private static func kind(of components: [PresentationIntent.IntentType]) -> Block.Kind {
        var ordinal: Int?
        var ordered: Bool?
        var depth = 0
        var heading: Int?
        var isCode = false
        var isQuote = false
        for component in components {
            switch component.kind {
            case .header(let level): heading = level
            case .codeBlock: isCode = true
            case .blockQuote: isQuote = true
            case .listItem(let n): if ordinal == nil { ordinal = n }
            case .orderedList:
                if ordered == nil { ordered = true }
                depth += 1
            case .unorderedList:
                if ordered == nil { ordered = false }
                depth += 1
            default: break
            }
        }
        if let heading { return .heading(heading) }
        if isCode { return .code }
        if let ordinal {
            return .item(marker: ordered == true ? "\(ordinal)." : "•", depth: max(depth - 1, 0))
        }
        return isQuote ? .quote : .paragraph
    }
}
