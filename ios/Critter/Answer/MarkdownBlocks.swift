import SwiftUI

/// Markdown as a plan has it: headings, lists, code, quotes and paragraphs, with bold, italics and `code` inside.
/// `AttributedString(markdown:)` reads it; `Text` shows the inline styles but not the blocks, so each block (the
/// runs that share a presentation intent) is laid out here. Text that does not parse is shown as it is.
struct MarkdownBlocks: View {
    let markdown: String

    var body: some View {
        if let blocks = Self.blocks(of: markdown) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(blocks) { block in
                    view(for: block, first: block.id == blocks.first?.id)
                }
            }
            .font(.nunito(size: Self.bodySize))
            .foregroundStyle(Theme.ink)
            .lineSpacing(Self.lineSpacing)
        } else {
            Text(verbatim: markdown)
                .font(.nunito(size: Self.bodySize, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .lineSpacing(Self.lineSpacing)
        }
    }

    // MARK: - Layout

    /// The plan paper's type (mockup "计划", Android `MarkdownLite`): 13.5 pt lines 1.65 apart, a 16 pt first-level
    /// heading and 13.5 pt bold ones under it, plain paragraphs in ink2, code in 12.5 pt monospace on the card's
    /// colour.
    private static let bodySize: CGFloat = 13.5
    private static let lineSpacing: CGFloat = bodySize * 0.65 - 4

    @ViewBuilder
    private func view(for block: Block, first: Bool) -> some View {
        switch block.kind {
        case .paragraph:
            Text(block.text)
                .font(.nunito(size: Self.bodySize, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .padding(.top, first ? 0 : 4)
        case .heading(let level):
            Text(block.text)
                .font(.nunito(size: level <= 1 ? 16 : Self.bodySize, weight: .heavy))
                .foregroundStyle(Theme.ink)
                .padding(.top, first ? 0 : 10)
                .padding(.bottom, level <= 1 ? 4 : 0)
        case .item(let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: marker)
                    .foregroundStyle(Theme.ink2)
                Text(block.text)
            }
            .padding(.leading, 6 + CGFloat(depth) * 16)
            .padding(.top, 2)
        case .code:
            Text(verbatim: String(block.text.characters).trimmingCharacters(in: .newlines))
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .lineSpacing(12.5 * 0.55 - 3)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: PixelShape(step: 2))
                .padding(.vertical, 6)
        case .quote:
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Theme.ink3)
                    .frame(width: 3)
                Text(block.text)
                    .foregroundStyle(Theme.ink2)
            }
            .padding(.top, first ? 0 : 4)
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
