import CoreGraphics
import Foundation

/// Pure geometry for the pet window: where each Clawd, its accessory, its name tag and its
/// speech bubble go, plus the collapse handle (expanded flock) or the per-state count chips
/// (merged pile). Coordinates use AppKit's bottom-left origin; the window is exactly
/// `Result.size`. Everything here is deterministic so it can be unit tested -- the views
/// only place themselves at these rects.
///
/// Column layout, bottom to top: tag, Clawd, accessory row, then (only if any session has
/// one) a bubble row whose bubbles all share one bottom edge. A column is as wide as its
/// bubble when it has one (`max(bubbleWidth, Clawd width)`), else Clawd width + 12, so
/// bubbles can never overlap each other or a neighbouring Clawd. A bubble-less column
/// widens (up to `bubbleWidth`) when its name tag needs the room, so a typical session
/// name like `robocup-81·未接入` isn't cut down to `robo…`.
public struct FlockLayout {
    public struct Metrics: Equatable, Sendable {
        public var scale: CGFloat
        public var bubbleWidth: CGFloat
        public var bubbleHeight: CGFloat
        public var columnGap: CGFloat
        public var padding: CGFloat
        public var tagHeight: CGFloat
        public var accessoryHeight: CGFloat
        public var handleSize: CGSize

        public init(
            scale: CGFloat,
            bubbleWidth: CGFloat = 132,
            bubbleHeight: CGFloat = 52,
            columnGap: CGFloat = 10,
            padding: CGFloat = 8,
            tagHeight: CGFloat = 24,
            accessoryHeight: CGFloat = 14,
            handleSize: CGSize = CGSize(width: 44, height: 18)
        ) {
            self.scale = scale
            self.bubbleWidth = bubbleWidth
            self.bubbleHeight = bubbleHeight
            self.columnGap = columnGap
            self.padding = padding
            self.tagHeight = tagHeight
            self.accessoryHeight = accessoryHeight
            self.handleSize = handleSize
        }

        /// One Clawd: 18×5 logical pixels of 3×6 pt each, times `scale`.
        public var clawdSize: CGSize { CGSize(width: 54 * scale, height: 30 * scale) }

        /// In the merged pile, each of the two Clawds stacked behind the front one is
        /// shifted right and up by this much relative to the one in front of it.
        public var pileStep: CGSize { CGSize(width: 12 * scale, height: 4 * scale) }
    }

    public struct Slot: Equatable, Sendable {
        /// The session id (`""` for the placeholder Clawd of the empty state).
        public var id: String
        /// The Clawd sprite -- for the merged pile, the whole pile (front Clawd at its
        /// bottom-left corner, the other two offset by `Metrics.pileStep`).
        public var clawd: CGRect
        /// The accessory row above the Clawd (`z z`, `•••`, `?`, …). In the merged pile the
        /// count chips take this row instead.
        public var accessory: CGRect
        public var tag: CGRect
        public var bubble: CGRect?
    }

    public struct Result: Equatable, Sendable {
        public var size: CGSize
        public var slots: [Slot]
        /// The "⇥ 收起" handle after the last column of an expanded flock.
        public var handle: CGRect?
        /// The merged pile's per-state count chips.
        public var chips: CGRect?
        /// Everything that should catch the mouse; the rest of the window is click-through.
        public var hitRects: [CGRect]

        /// What a click at `point` (window coordinates) lands on: a slot's Clawd, bubble or
        /// tag, the collapse handle, or the count chips -- nil for click-through space.
        public func target(at point: CGPoint) -> HitTarget? {
            if let handle, handle.contains(point) { return .handle }
            if let chips, chips.contains(point) { return .chips }
            return slots.firstIndex { slot in
                slot.clawd.contains(point) || slot.tag.contains(point) || (slot.bubble?.contains(point) ?? false)
            }.map { .slot($0) }
        }
    }

    public enum HitTarget: Equatable, Sendable {
        case slot(Int)
        case handle
        case chips
    }

    // Small fixed spacings between the rows of a column.
    static let tagToClawdGap: CGFloat = 2
    static let clawdToAccessoryGap: CGFloat = 2
    static let accessoryToBubbleGap: CGFloat = 4
    static let bareColumnExtra: CGFloat = 12
    static let chipGap: CGFloat = 4
    static let chipFontSize: CGFloat = 9
    static let tagFontSize: CGFloat = 10
    static let tagHorizontalPadding: CGFloat = 12

    public static func mergedTagText(total: Int) -> String {
        "\(total) 个会话 · 点击展开"
    }

    /// The name shown on a session's tag; sessions Clawd has no hook data for are marked.
    public static func tagText(for session: PetSession) -> String {
        session.tracked ? session.name : "\(session.name)·未接入"
    }

    /// The empty state's placeholder Clawd: its tag reads `Clawd` over `暂无会话`.
    public static let emptyTagText = "Clawd"

    /// The text of one count chip, e.g. `? 1`, `✓ 1`, `••• 2`.
    public static func chipLabel(_ count: StateCount) -> String {
        "\(count.state.accessory) \(count.count)"
    }

    /// A generous estimate of a chip's width (the views center the real text inside).
    public static func chipWidth(_ count: StateCount) -> CGFloat {
        estimatedTextWidth(chipLabel(count), fontSize: chipFontSize) + 10
    }

    /// The presentation to actually show in a window at most `maxWidth` wide. Columns
    /// don't wrap, so an expanded flock too wide for the screen (many sessions, a high merge
    /// threshold or a manual "展开") is shown merged instead: otherwise its far end -- the
    /// "⇥ 收起" handle included -- would be pushed off screen, out of reach.
    public static func fitted(_ presentation: FlockPresentation, metrics: Metrics, maxWidth: CGFloat) -> FlockPresentation {
        guard case .expanded(let sessions, _) = presentation, sessions.count >= 2,
              layout(presentation, metrics: metrics).size.width > maxWidth
        else { return presentation }
        return FlockModel.merged(sessions)
    }

    public static func layout(_ p: FlockPresentation, metrics m: Metrics) -> Result {
        switch p {
        case .empty:
            return layoutColumns([Column(id: "", hasBubble: false, tagText: emptyTagText)], showHandle: false, metrics: m)
        case .expanded(let sessions, let showCollapse):
            let columns = sessions.map { Column(id: $0.id, hasBubble: $0.state != .idle, tagText: tagText(for: $0)) }
            return layoutColumns(columns, showHandle: showCollapse, metrics: m)
        case .merged(let lead, let counts, let total):
            return layoutPile(leadId: lead.id, hasBubble: lead.state != .idle, counts: counts, total: total, metrics: m)
        }
    }

    // MARK: - Expanded / empty

    private struct Column {
        var id: String
        var hasBubble: Bool
        var tagText: String
    }

    private static func layoutColumns(_ columns: [Column], showHandle: Bool, metrics m: Metrics) -> Result {
        let clawd = m.clawdSize
        let anyBubble = columns.contains { $0.hasBubble }
        let rows = Rows(metrics: m, clawdAreaHeight: clawd.height, hasBubbleRow: anyBubble)

        var slots: [Slot] = []
        var x = m.padding
        for (index, column) in columns.enumerated() {
            if index > 0 { x += m.columnGap }
            let width = column.hasBubble
                ? max(m.bubbleWidth, clawd.width)
                : max(clawd.width + bareColumnExtra, min(tagWidth(column.tagText), m.bubbleWidth))
            slots.append(Slot(
                id: column.id,
                clawd: CGRect(x: x + (width - clawd.width) / 2, y: rows.clawdY, width: clawd.width, height: clawd.height),
                accessory: CGRect(x: x, y: rows.accessoryY, width: width, height: m.accessoryHeight),
                tag: CGRect(x: x, y: rows.tagY, width: width, height: m.tagHeight),
                bubble: column.hasBubble
                    ? CGRect(x: x + (width - m.bubbleWidth) / 2, y: rows.bubbleY, width: m.bubbleWidth, height: m.bubbleHeight)
                    : nil
            ))
            x += width
        }

        var handle: CGRect?
        if showHandle {
            x += m.columnGap
            let clawdMidY = rows.clawdY + clawd.height / 2
            handle = CGRect(
                x: x, y: clawdMidY - m.handleSize.height / 2,
                width: m.handleSize.width, height: m.handleSize.height
            )
            x += m.handleSize.width
        }

        let size = CGSize(width: x + m.padding, height: rows.totalHeight)
        let hitRects = slots.flatMap { [$0.clawd, $0.tag] + ($0.bubble.map { [$0] } ?? []) } + (handle.map { [$0] } ?? [])
        return Result(size: size, slots: slots, handle: handle, chips: nil, hitRects: hitRects)
    }

    // MARK: - Merged pile

    private static func layoutPile(leadId: String, hasBubble: Bool, counts: [StateCount], total: Int, metrics m: Metrics) -> Result {
        let clawd = m.clawdSize
        let pile = CGSize(width: clawd.width + 2 * m.pileStep.width, height: clawd.height + 2 * m.pileStep.height)
        let rows = Rows(metrics: m, clawdAreaHeight: pile.height, hasBubbleRow: hasBubble)

        let chipsWidth = counts.map(chipWidth).reduce(0, +) + chipGap * CGFloat(max(counts.count - 1, 0))
        let width = max(
            hasBubble ? max(m.bubbleWidth, pile.width) : pile.width + bareColumnExtra,
            chipsWidth,
            tagWidth(mergedTagText(total: total))
        )

        let x = m.padding
        let chips = CGRect(x: x + (width - chipsWidth) / 2, y: rows.accessoryY, width: chipsWidth, height: m.accessoryHeight)
        let slot = Slot(
            id: leadId,
            clawd: CGRect(x: x + (width - pile.width) / 2, y: rows.clawdY, width: pile.width, height: pile.height),
            accessory: chips,
            tag: CGRect(x: x, y: rows.tagY, width: width, height: m.tagHeight),
            bubble: hasBubble
                ? CGRect(x: x + (width - m.bubbleWidth) / 2, y: rows.bubbleY, width: m.bubbleWidth, height: m.bubbleHeight)
                : nil
        )

        let size = CGSize(width: x + width + m.padding, height: rows.totalHeight)
        let hitRects = [slot.clawd, slot.tag] + (slot.bubble.map { [$0] } ?? []) + [chips]
        return Result(size: size, slots: [slot], handle: nil, chips: chips, hitRects: hitRects)
    }

    // MARK: - Helpers

    /// The y coordinates of each row, shared by every column so rows line up.
    private struct Rows {
        var tagY: CGFloat
        var clawdY: CGFloat
        var accessoryY: CGFloat
        var bubbleY: CGFloat
        var totalHeight: CGFloat

        init(metrics m: Metrics, clawdAreaHeight: CGFloat, hasBubbleRow: Bool) {
            tagY = m.padding
            clawdY = tagY + m.tagHeight + FlockLayout.tagToClawdGap
            accessoryY = clawdY + clawdAreaHeight + FlockLayout.clawdToAccessoryGap
            bubbleY = accessoryY + m.accessoryHeight + FlockLayout.accessoryToBubbleGap
            totalHeight = (hasBubbleRow ? bubbleY + m.bubbleHeight : accessoryY + m.accessoryHeight) + m.padding
        }
    }

    private static func tagWidth(_ text: String) -> CGFloat {
        estimatedTextWidth(text, fontSize: tagFontSize) + tagHorizontalPadding
    }

    /// Rough rendered width of `text` in the system font: CJK and other wide characters
    /// take about one em, everything else about 0.6 em. Deliberately on the generous side.
    static func estimatedTextWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        text.unicodeScalars.reduce(0) { width, scalar in
            width + (scalar.value >= 0x2E80 ? fontSize : fontSize * 0.6)
        }
    }
}
