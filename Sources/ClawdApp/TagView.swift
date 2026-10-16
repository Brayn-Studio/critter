import AppKit
import ClawdCore

/// The label under a Clawd: the session name (10 pt, white on a pill tinted by state) and,
/// below it, the source (8 pt). A session Clawd has no hook data for yet gets `·未接入`
/// after its name. The merged pile uses it with a single line (`5 个会话 · 点击展开`).
final class TagView: NSView {
    private static let pillHeight: CGFloat = 14
    private static let pillPadding: CGFloat = 5
    private static let sourceHeight: CGFloat = 10

    private let pill = NSView()
    private let name = NSTextField(labelWithString: "")
    private let source = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        pill.wantsLayer = true
        pill.layer?.cornerRadius = 6
        addSubview(pill)

        name.font = .systemFont(ofSize: 10, weight: .medium)
        name.textColor = .white
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        pill.addSubview(name)

        // White with a dark shadow reads on light and dark wallpapers alike.
        source.font = .systemFont(ofSize: 8)
        source.textColor = NSColor(white: 1, alpha: 0.9)
        source.alignment = .center
        source.lineBreakMode = .byTruncatingTail
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.8)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        source.shadow = shadow
        addSubview(source)
    }

    required init?(coder: NSCoder) {
        fatalError("TagView does not support NSCoding")
    }

    func configure(session: PetSession) {
        configure(
            name: FlockLayout.tagText(for: session),
            source: session.source.label,
            color: session.state.tagColor,
            toolTip: session.tracked ? nil : session.detail
        )
    }

    func configure(name text: String, source sourceText: String?, color: NSColor, toolTip tip: String? = nil) {
        name.stringValue = text
        source.stringValue = sourceText ?? ""
        source.isHidden = sourceText == nil
        pill.layer?.backgroundColor = color.cgColor
        toolTip = tip
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let textWidth = ceil(name.intrinsicContentSize.width)
        let pillWidth = min(bounds.width, textWidth + 2 * Self.pillPadding)
        let pillY = source.isHidden ? (bounds.height - Self.pillHeight) / 2 : bounds.height - Self.pillHeight
        pill.frame = NSRect(x: (bounds.width - pillWidth) / 2, y: pillY, width: pillWidth, height: Self.pillHeight)
        name.frame = pill.bounds.insetBy(dx: Self.pillPadding - 2, dy: 0).offsetBy(dx: 0, dy: -1)
        source.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.sourceHeight)
    }
}
