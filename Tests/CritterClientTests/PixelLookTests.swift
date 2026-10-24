import CoreGraphics
import CritterKit
import Testing
@testable import CritterClient

/// Twice the signed area (shoelace); positive for a clockwise outline in y-down coordinates.
private func doubleArea(_ p: [CGPoint]) -> CGFloat {
    var sum: CGFloat = 0
    for i in p.indices {
        let j = (i + 1) % p.count
        sum += p[i].x * p[j].y - p[j].x * p[i].y
    }
    return sum
}

@Test func fullOutlineHasTwentyCornersClockwise() {
    let p = PixelOutline.points(width: 100, height: 40, step: 4)
    #expect(p.count == 20)
    #expect(Array(p.prefix(5)) == [
        CGPoint(x: 0, y: 8), CGPoint(x: 4, y: 8), CGPoint(x: 4, y: 4), CGPoint(x: 8, y: 4), CGPoint(x: 8, y: 0),
    ])
    #expect(p[5] == CGPoint(x: 92, y: 0))
    // Each corner cuts three step squares off the box.
    let expected: CGFloat = 2 * (100 * 40 - 4 * 3 * 16)
    #expect(doubleArea(p) == expected)
}

@Test func topOnlyKeepsSquareBottom() {
    let p = PixelOutline.points(width: 100, height: 40, step: 4, topOnly: true)
    #expect(p.count == 12)
    #expect(Array(p.suffix(2)) == [CGPoint(x: 100, y: 40), CGPoint(x: 0, y: 40)])
    let expected: CGFloat = 2 * (100 * 40 - 2 * 3 * 16)
    #expect(doubleArea(p) == expected)
}

@Test func stepIsClampedToAQuarterOfTheShortSide() {
    #expect(PixelOutline.points(width: 10, height: 10, step: 4)[0].y == 4)
}

@Test func everyIconIsRectangular() {
    for icon in PixelIcon.allCases {
        let rows = PixelIcons.rows(icon)
        #expect(!rows.isEmpty, "\(icon)")
        #expect(rows.allSatisfy { $0.count == rows[0].count }, "\(icon)")
        #expect(rows.allSatisfy { $0.allSatisfy { $0 == "#" || $0 == "." } }, "\(icon)")
    }
    #expect(PixelIcons.rows(.seed)[0].count == 8)
    let z = PixelIcons.rows(.z)
    #expect(z[0].count == 5 && z.count == 5)
}

@Test func theIconSetIsTheDesignsList() {
    let names = [
        "board", "sliders", "back", "close", "folder", "branch", "term", "editor", "laptop", "wifi", "bell", "battery",
        "send", "letter", "qr", "keys", "chevR", "chevD", "chevU", "lock", "ball", "grid", "paw", "spark", "seedling",
        "seed", "bud", "sprout", "dot", "sun", "q", "bang", "check", "z", "moon",
    ]
    #expect(PixelIcon.allCases.map(\.rawValue) == names)
}

@Test func everyStateHasAnIcon() {
    for state in PetState.allCases {
        #expect(PixelIcon.allCases.contains(PixelIcon.forState(state)), "\(state)")
    }
    #expect(PixelIcon.forState(.waiting) == .q)
    #expect(PixelIcon.forState(.running) == .sun)
    #expect(PixelIcon.forState(.done) == .check)
    #expect(PixelIcon.forState(.error) == .bang)
    #expect(PixelIcon.forState(.idle) == .z)
}

@Test func runsCoverEveryPixelOnce() {
    for icon in PixelIcon.allCases {
        let rows = PixelIcons.rows(icon)
        let runs = PixelIcons.runs(rows)
        #expect(runs.map(\.length).reduce(0, +) == rows.reduce(0) { $0 + $1.filter { $0 == "#" }.count }, "\(icon)")
        var seen = Set<[Int]>()
        for run in runs {
            for cx in run.x..<(run.x + run.length) {
                #expect(Array(rows[run.y])[cx] == "#", "\(icon) (\(cx), \(run.y))")
                #expect(seen.insert([cx, run.y]).inserted, "\(icon) overlaps at (\(cx), \(run.y))")
            }
        }
    }
    #expect(PixelIcons.runs(.dot) == [PixelRun(x: 0, y: 0, length: 2), PixelRun(x: 0, y: 1, length: 2)])
    #expect(PixelIcons.runs(["#.##", "...."]) == [PixelRun(x: 0, y: 0, length: 1), PixelRun(x: 2, y: 0, length: 2)])
}

@Test func litSegmentsRoundsAndClamps() {
    #expect(Meters.litSegments(fraction: 0.11, count: 10) == 1)
    #expect(Meters.litSegments(fraction: 0.62, count: 10) == 6)
    #expect(Meters.litSegments(fraction: 1.0, count: 10) == 10)
    #expect(Meters.litSegments(fraction: 1.4, count: 10) == 10)
    #expect(Meters.litSegments(fraction: -0.05, count: 10) == 0)
    #expect(Meters.litSegments(fraction: nil, count: 20) == 0)
    #expect(Meters.litSegments(fraction: 0.32, count: 24) == 8)
}

@Test func meterLevelsSplitAtSixtyAndEightyFive() {
    #expect(Meters.level(percent: 59.9) == .calm)
    #expect(Meters.level(percent: 60.0) == .busy)
    #expect(Meters.level(percent: 84.9) == .busy)
    #expect(Meters.level(percent: 85.0) == .hot)
    #expect(Meters.level(percent: nil) == .calm)
}

@Test func steppedFractionMovesInThirds() {
    #expect(Stepped.fraction(0.2) == 0)
    #expect(Stepped.fraction(0.5) == 1.0 / 3)
    #expect(Stepped.fraction(0.99) == 2.0 / 3)
    #expect(Stepped.fraction(1) == 1)
    #expect(Stepped.fraction(-0.2) == 0)
    #expect(Stepped.fraction(0.5, steps: 4) == 0.5)
}

@Test func wordmarkIsFortyTwoByNine() {
    #expect(Wordmark.rows.count == 9 && Wordmark.rows.allSatisfy { $0.count == 42 })
    let cells = Wordmark.cells
    #expect(cells.allSatisfy { (0...41).contains($0.x) && (0...8).contains($0.y) })
    #expect(cells.map(\.x).max() == 41)
    #expect(cells.map(\.y).max() == 8)
    let sprout = cells.filter { $0.kind != .ink }
    #expect(sprout.allSatisfy { (0...1).contains($0.y) && (13...16).contains($0.x) })
    #expect(sprout.filter { $0.kind == .leaf }.count == 2)
    #expect(sprout.filter { $0.kind == .stem }.count == 2)
}
