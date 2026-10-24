import CoreGraphics

/// Where each Critter stands on the board's Critter mode (landscape, lengths in pt). One row of at most
/// `maxPerRow` Critters, each 18 cells wide with a gap of 4 cells, drawn at 6 pt per cell (design §8.7), or
/// smaller (5, 4, then 3) as the row fills. More Critters than fit are not squeezed further: the last slot becomes
/// a pile, and the sessions from `Layout.pileFrom` on merge into it (it needs room for the two back rows too).
/// The same numbers as Android's `BoardLayout`, dp for pt.
public enum BoardLayout {
    public static let maxPerRow = 6
    public static let maxScale: CGFloat = 6
    public static let minScale: CGFloat = 3
    private static let cells: CGFloat = 18
    private static let gapCells: CGFloat = 4
    private static let pileExtraCells: CGFloat = 7
    private static let margin: CGFloat = 24
    /// A Critter with its bubble above the ground line and its name below, in cells: the row may fill 70% of
    /// the height at most.
    private static let heightCells: CGFloat = 28

    /// The room above a Critter's ground line (bubble, marker) and below it (name, branch, context line).
    private static let groundFraction: CGFloat = 0.6

    /// `scale` is pt per cell; `slots` are the top-left of each base box's column 0 as x, and the ground line as
    /// y; `pileFrom` is the index of the first session in the pile (the last slot), or nil.
    public struct Layout: Equatable, Sendable {
        public var scale: CGFloat
        public var slots: [CGPoint]
        public var pileFrom: Int?

        public init(scale: CGFloat, slots: [CGPoint], pileFrom: Int?) {
            self.scale = scale
            self.slots = slots
            self.pileFrom = pileFrom
        }
    }

    public static func place(count: Int, width: CGFloat, height: CGFloat) -> Layout {
        if count <= 0 { return Layout(scale: maxScale, slots: [], pileFrom: nil) }
        // How many slots fit at the smallest scale (the pile counts for its extra width).
        var capacity = maxPerRow
        while capacity > 1 && rowWidth(capacity, scale: minScale, pile: count > capacity) > width { capacity -= 1 }
        let slotCount = min(count, capacity)
        let pile = count > slotCount
        var scale = maxScale
        while scale > minScale && (rowWidth(slotCount, scale: scale, pile: pile) > width || scale * heightCells > height * 0.7) {
            scale -= 1
        }
        let total = rowWidth(slotCount, scale: scale, pile: pile) - 2 * margin
        let x0 = (width - total) / 2
        let ground = height * groundFraction
        let pitch = (cells + gapCells) * scale
        let slots = (0..<slotCount).map { CGPoint(x: x0 + CGFloat($0) * pitch, y: ground) }
        return Layout(scale: scale, slots: slots, pileFrom: pile ? slotCount - 1 : nil)
    }

    /// One row at a fixed `scale` (pt per cell), standing on `ground` (the home meadow): `place`'s rule without the
    /// shrinking. At most `maxPerRow` slots, as many as fit between margins of `margin`; when there are more
    /// Critters than that, the last slot becomes the pile and the row is packed and centred, the pile's extra width
    /// included. When they all fit, they spread out evenly between the margins, as on the mockups' meadow: each
    /// gets an equal share of the width and stands in the middle of it (never closer than the packed row).
    public static func placeRow(count: Int, width: CGFloat, ground: CGFloat, scale: CGFloat, margin: CGFloat, maxPerRow: Int) -> Layout {
        if count <= 0 { return Layout(scale: scale, slots: [], pileFrom: nil) }
        var capacity = maxPerRow
        while capacity > 1 && rowWidth(capacity, scale: scale, pile: count > capacity, margin: margin) > width { capacity -= 1 }
        let slotCount = min(count, capacity)
        let pile = count > slotCount
        let packed = (cells + gapCells) * scale
        let slots: [CGPoint]
        if pile {
            let x0 = (width - rowWidth(slotCount, scale: scale, pile: pile, margin: 0)) / 2
            slots = (0..<slotCount).map { CGPoint(x: x0 + CGFloat($0) * packed, y: ground) }
        } else {
            let share = max(packed, (width - 2 * margin) / CGFloat(slotCount))
            let first = (width - share * CGFloat(slotCount)) / 2 + (share - cells * scale) / 2
            slots = (0..<slotCount).map { CGPoint(x: first + CGFloat($0) * share, y: ground) }
        }
        return Layout(scale: scale, slots: slots, pileFrom: pile ? slotCount - 1 : nil)
    }

    private static func rowWidth(_ n: Int, scale: CGFloat, pile: Bool, margin: CGFloat = BoardLayout.margin) -> CGFloat {
        ((cells + gapCells) * CGFloat(n) - gapCells + (pile ? pileExtraCells : 0)) * scale + 2 * margin
    }
}
