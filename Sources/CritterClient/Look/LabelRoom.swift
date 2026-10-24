import CoreGraphics
import Foundation

/// How wide a label under a Critter on the home meadow may be (Android `labelRoom`), so name tags, bubbles and
/// pile counts never overlap.
public enum LabelRoom {
    /// How wide the label centred on slot `index` of a row may be (everything in pt: the slots' `centers`, each
    /// label's `natural` width, the row `width`). Towards the nearest neighbour on each side with a label at the
    /// same height (`taken`) it may use the space between them, less `gap`, that the neighbour's label leaves: a
    /// neighbour keeps half of it at most, less when its natural width needs less. With no neighbour it reaches
    /// `edge` from the side. Labels stay centred and never overlap; a longer text is cut short.
    public static func room(
        centers: [CGFloat], natural: [CGFloat], index i: Int, width: CGFloat, gap: CGFloat = 4, edge: CGFloat = 4,
        taken: (Int) -> Bool = { _ in true }
    ) -> CGFloat {
        let c = centers[i]
        func half(_ j: Int) -> CGFloat {
            let space = abs(c - centers[j]) - gap
            return space - min(natural[j] / 2, space / 2)
        }
        let left = stride(from: i - 1, through: 0, by: -1).first(where: taken).map(half) ?? (c - edge)
        let right = ((i + 1)..<centers.count).first(where: taken).map(half) ?? (width - edge - c)
        return max(2 * min(left, right), 0)
    }

    /// `room` for every slot of the row.
    public static func rooms(
        centers: [CGFloat], natural: [CGFloat], width: CGFloat, gap: CGFloat = 4, edge: CGFloat = 4,
        taken: (Int) -> Bool = { _ in true }
    ) -> [CGFloat] {
        centers.indices.map {
            room(centers: centers, natural: natural, index: $0, width: width, gap: gap, edge: edge, taken: taken)
        }
    }
}
