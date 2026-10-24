import CoreGraphics
import Testing
@testable import CritterClient

private let gap: CGFloat = 4
private let edge: CGFloat = 4

private func rooms(
    _ centers: [CGFloat], _ natural: [CGFloat], _ width: CGFloat, taken: (Int) -> Bool = { _ in true }
) -> [CGFloat] {
    LabelRoom.rooms(centers: centers, natural: natural, width: width, gap: gap, edge: edge, taken: taken)
}

/// Each label as drawn: centred, its natural width cut to its room.
private func spans(_ centers: [CGFloat], _ natural: [CGFloat], _ rooms: [CGFloat]) -> [(CGFloat, CGFloat)] {
    centers.indices.map {
        let w = min(natural[$0], rooms[$0])
        return (centers[$0] - w / 2, centers[$0] + w / 2)
    }
}

private func assertApart(_ spans: [(CGFloat, CGFloat)], _ width: CGFloat) {
    for k in 1..<max(spans.count, 1) {
        #expect(spans[k].0 - spans[k - 1].1 >= gap - 0.001, "labels \(k - 1) and \(k) overlap: \(spans)")
    }
    #expect(spans.first!.0 >= edge - 0.001 && spans.last!.1 <= width - edge + 0.001, "past an edge: \(spans)")
}

/// Two short neighbours each leave the other more than half the space between them.
@Test func twoShortNeighboursShareTheSpace() {
    let centers: [CGFloat] = [100, 200]
    let natural: [CGFloat] = [40, 40]
    let r = rooms(centers, natural, 300)
    // 96 pt between them less the other's 20 pt half, on both sides: 2 × 76.
    #expect(r == [152, 152])
    assertApart(spans(centers, natural, r), 300)
}

/// A long name between two short ones takes what they leave, and is cut short there; theirs stay whole.
@Test func aLongNameBetweenShortOnesTakesWhatTheyLeave() {
    let centers: [CGFloat] = [60, 150, 240]
    let natural: [CGFloat] = [30, 300, 30]
    let r = rooms(centers, natural, 300)
    // 86 pt to each neighbour, less its 15 pt half: 2 × 71.
    #expect(r[1] == 142)
    // The short ones get only half the space towards the long one, which is still all they need.
    #expect(r[0] == 86)
    #expect(r[2] == 86)
    let s = spans(centers, natural, r)
    #expect(s[0].1 - s[0].0 == 30)
    #expect(s[1].1 - s[1].0 == 142)
    assertApart(s, 300)
}

/// With no neighbour a label reaches 4 pt from the meadow's sides, from its centre: near a side it is narrow.
@Test func theEdgesOfTheMeadow() {
    #expect(rooms([150], [400], 300)[0] == 292)
    let centers: [CGFloat] = [30, 270]
    let natural: [CGFloat] = [200, 200]
    let r = rooms(centers, natural, 300)
    #expect(r == [52, 52])
    assertApart(spans(centers, natural, r), 300)
    // A centre closer to the side than the edge leaves no room at all, rather than a negative one.
    #expect(rooms([2], [50], 300)[0] == 0)
}

/// A neighbour with nothing at this height (no bubble) does not count: the next one, or the side, does.
@Test func onlyNeighboursWithALabelAtThatHeightCount() {
    let centers: [CGFloat] = [60, 150, 240]
    let natural: [CGFloat] = [200, .greatestFiniteMagnitude, 200]
    let r = rooms(centers, natural, 300) { $0 != 1 }
    // Slot 0 looks past slot 1 to slot 2: 176 pt less half of it (88), against 56 pt to the side.
    #expect(r[0] == 112)
    #expect(r[2] == 112)
}

@Test func theGapAndEdgeDefaultToFourPoints() {
    #expect(LabelRoom.rooms(centers: [100, 200], natural: [40, 40], width: 300) == [152, 152])
    #expect(LabelRoom.room(centers: [150], natural: [400], index: 0, width: 300) == 292)
}
