import CoreGraphics
import Testing
@testable import CritterClient

private func assertInside(_ layout: BoardLayout.Layout, _ w: CGFloat, _ h: CGFloat) {
    for (i, p) in layout.slots.enumerated() {
        let cells: CGFloat = i == layout.pileFrom ? 25 : 18 // the pile's back rows reach 7 cells further
        #expect(p.x >= 0 && p.x + cells * layout.scale <= w, "slot x=\(p.x) scale=\(layout.scale) outside width \(w)")
        #expect(p.y >= 0 && p.y <= h, "ground y=\(p.y) outside height \(h)")
    }
}

@Test func zeroSessionsHaveNoSlots() {
    let l = BoardLayout.place(count: 0, width: 740, height: 360)
    #expect(l.slots.isEmpty)
    #expect(l.pileFrom == nil)
}

@Test func oneSessionIsBigAndCentred() {
    let l = BoardLayout.place(count: 1, width: 740, height: 360)
    #expect(l.slots.count == 1)
    #expect(l.scale == 6)
    #expect(l.pileFrom == nil)
    assertInside(l, 740, 360)
    #expect(abs(740.0 / 2 - (l.slots[0].x + 9 * l.scale)) <= 0.5)
}

@Test func sixSessionsFitWithoutAPile() {
    for w: CGFloat in [740, 800, 915] {
        let l = BoardLayout.place(count: 6, width: w, height: 360)
        #expect(l.slots.count == 6)
        #expect(l.pileFrom == nil)
        #expect((3...6).contains(l.scale))
        assertInside(l, w, 360)
    }
}

@Test func sevenSessionsMergeFromTheSixthSlot() {
    let l = BoardLayout.place(count: 7, width: 800, height: 360)
    #expect(l.slots.count == 6)
    #expect(l.pileFrom == 5)
    assertInside(l, 800, 360)
}

@Test func twelveSessionsStayInside() {
    let l = BoardLayout.place(count: 12, width: 800, height: 360)
    #expect(l.slots.count == 6)
    #expect(l.pileFrom == 5)
    assertInside(l, 800, 360)
}

@Test func aNarrowScreenPilesEarlierInsteadOfOverflowing() {
    let l = BoardLayout.place(count: 6, width: 300, height: 360)
    #expect(l.slots.count < 6)
    #expect(l.pileFrom == l.slots.count - 1)
    assertInside(l, 300, 360)
}

/// Design §8.7: 6 pt a cell, as on the mockup's 800 x 360 board with five sessions.
@Test func fiveSessionsAreSixPtACellOnAPhone() {
    let l = BoardLayout.place(count: 5, width: 800, height: 360)
    #expect(l.scale == 6)
    #expect(l.pileFrom == nil)
    assertInside(l, 800, 360)
}

@Test func scaleShrinksFromSixToThreeAsTheRowFills() {
    let few = BoardLayout.place(count: 2, width: 800, height: 360).scale
    let many = BoardLayout.place(count: 6, width: 800, height: 360).scale
    #expect(few >= many)
    #expect(BoardLayout.place(count: 6, width: 450, height: 360).scale == 3)
}

// The home meadow's row: 3 pt a cell on a 360 pt phone, the ground at 200 pt, 12 pt margins, at most 5 slots.

@Test func placeRowFitsFiveOnAPhone() {
    let l = BoardLayout.placeRow(count: 5, width: 360, ground: 200, scale: 3, margin: 12, maxPerRow: 5)
    #expect(l.slots.count == 5)
    #expect(l.pileFrom == nil)
    #expect(l.scale == 3)
    // An equal 67.2 pt share each between the 12 pt margins, the 54 pt base box in the middle of it.
    for (want, got) in zip([18.6, 85.8, 153.0, 220.2, 287.4], l.slots.map(\.x)) {
        #expect(abs(want - got) <= 0.01, "\(want) vs \(got)")
    }
    #expect(l.slots.allSatisfy { $0.y == 200 })
}

@Test func placeRowSpreadsAFewAcrossTheMeadow() {
    // Two sessions stand in the middle of each half (centres 96 and 264), not packed together in the middle.
    #expect(BoardLayout.placeRow(count: 2, width: 360, ground: 200, scale: 3, margin: 12, maxPerRow: 5).slots.map(\.x) == [69, 237])
    #expect(BoardLayout.placeRow(count: 1, width: 360, ground: 200, scale: 3, margin: 12, maxPerRow: 5).slots.map(\.x) == [153])
}

@Test func placeRowPilesTheRest() {
    for count in [7, 12] {
        let l = BoardLayout.placeRow(count: count, width: 360, ground: 200, scale: 3, margin: 12, maxPerRow: 5)
        #expect(l.slots.count == 4, "\(count) sessions")
        #expect(l.pileFrom == 3, "\(count) sessions")
        #expect(l.scale == 3)
        assertInside(l, 360, 360)
    }
}

@Test func placeRowEmpty() {
    let l = BoardLayout.placeRow(count: 0, width: 360, ground: 200, scale: 3, margin: 12, maxPerRow: 5)
    #expect(l.slots.isEmpty)
    #expect(l.pileFrom == nil)
}

/// 12 sessions on an iPhone 17 Pro in landscape (874 x 402 pt): six slots at the biggest size, the last one
/// the pile, no slot over another and the row (the pile's back rows included) inside the screen.
@Test func boardLayoutPilesWhatDoesNotFit() {
    let l = BoardLayout.place(count: 12, width: 874, height: 402)
    #expect(l.slots.count == 6)
    #expect(l.scale == 6)
    #expect(l.pileFrom == 5)
    assertInside(l, 874, 402)
    // Each slot is 18 cells wide (the pile 25), and the next one starts 22 cells on.
    for (a, b) in zip(l.slots, l.slots.dropFirst()) {
        #expect(a.x + 18 * l.scale <= b.x, "slots at \(a.x) and \(b.x) overlap")
    }
    // The ground line is the same for all of them, 60% of the way down.
    #expect(l.slots.allSatisfy { abs($0.y - 402 * 0.6) < 0.001 })
    // Centred: the same room left and right of the row.
    let last = l.slots[5].x + 25 * l.scale
    #expect(abs(l.slots[0].x - (874 - last)) < 0.001)
}
