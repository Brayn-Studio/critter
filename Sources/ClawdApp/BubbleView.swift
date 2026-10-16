import AppKit
import ClawdCore

/// One session's speech bubble: a white rounded card with a 4 pt state-color stripe on the
/// left, a small `<来源> · <名字>` header line, and the detail text in at most two lines
/// (truncated with "…"). Hovering shows the full detail as a tooltip.
final class BubbleView: NSView {
    static let stripeWidth: CGFloat = 4
    private static let cornerRadius: CGFloat = 10
    private static let insets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
    private static let headerHeight: CGFloat = 12
    /// Whitespace runs are collapsed and very long text cut short before AppKit's own
    /// two-line tail truncation, so layout never has to measure a novel.
    private static let maxDisplayCharacters = 160

    private let card = NSView()
    private let stripe = NSView()
    private let header = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = Self.cornerRadius
        card.layer?.masksToBounds = true
        addSubview(card)

        stripe.wantsLayer = true
        card.addSubview(stripe)

        header.font = .systemFont(ofSize: 9)
        header.textColor = NSColor(hex: "#6E6E73")
        header.lineBreakMode = .byTruncatingTail
        header.maximumNumberOfLines = 1
        card.addSubview(header)

        detail.font = .systemFont(ofSize: 11)
        detail.textColor = NSColor(hex: "#1D1D1F")
        // Wrap onto at most two lines; the second one ends in "…" if there's more.
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byWordWrapping
        detail.cell?.truncatesLastVisibleLine = true
        card.addSubview(detail)
    }

    required init?(coder: NSCoder) {
        fatalError("BubbleView does not support NSCoding")
    }

    func configure(session: PetSession) {
        let full = session.detail.flatMap { $0.isEmpty ? nil : $0 } ?? session.state.label
        header.stringValue = "\(session.source.label) · \(session.name)"
        detail.stringValue = ToolSummary.truncate(full, max: Self.maxDisplayCharacters)
        stripe.layer?.backgroundColor = session.state.color.cgColor
        toolTip = full
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil
        )
        stripe.frame = NSRect(x: 0, y: 0, width: Self.stripeWidth, height: bounds.height)

        let left = Self.stripeWidth + Self.insets.left
        let width = bounds.width - left - Self.insets.right
        let headerY = bounds.height - Self.insets.top - Self.headerHeight
        header.frame = NSRect(x: left, y: headerY, width: width, height: Self.headerHeight)
        detail.frame = NSRect(x: left, y: Self.insets.bottom, width: width, height: headerY - Self.insets.bottom)
    }
}
