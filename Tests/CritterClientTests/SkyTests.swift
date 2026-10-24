import CoreGraphics
import Testing
@testable import CritterClient

private func meadow(_ time: SkyTime, seed: Int = 7) -> [MeadowCell] {
    meadowCells(width: 360, height: 236, ground: 200, cell: 3, time: time, seed: seed)
}

@Test func hoursMapToFourSkies() {
    let expected: [Int: SkyTime] = [
        5: .night, 6: .dawn, 9: .dawn, 10: .day, 16: .day, 17: .dusk, 19: .dusk, 20: .night,
    ]
    for (hour, sky) in expected {
        #expect(SkyTime.at(hour: hour, dark: false) == sky, "hour \(hour)")
    }
    #expect(SkyTime.at(hour: 12, dark: true) == .night)
    #expect(SkyTime.at(hour: 12) == .day)
}

@Test func duskAndNightTextIsWhite() {
    #expect(SkyColors.of(.dusk).onSky == 0xFFFFFF)
    #expect(SkyColors.of(.night).onSky == 0xF3F0FC)
    #expect(SkyColors.of(.day).onSky == 0x2A2140)
}

@Test func nameTagsAreWhiteByDayAndDarkAtNight() {
    #expect(SkyColors.of(.day).tag == 0xFFFFFF && SkyColors.of(.day).tagOpacity == 0.88)
    #expect(SkyColors.of(.dusk).tagInk == 0x2A2140)
    #expect(SkyColors.of(.night).tag == 0x17142A && SkyColors.of(.night).tagOpacity == 0.82)
    #expect(SkyColors.of(.night).tagInk == 0xF3F0FC)
}

@Test func bandsSplitAtFortyTwoAndSeventyFourPercent() {
    let sky = SkyColors.of(.day)
    let cells = meadow(.day)
    #expect(cells.contains { $0.y == 0 && $0.w == 360 && $0.color == sky.top })
    #expect(cells.contains { $0.y == 84 && $0.w == 360 && $0.color == sky.middle })
    #expect(cells.contains { $0.y == 147 && $0.w == 360 && $0.color == sky.bottom })
}

@Test func eachBandEdgeDithersOneRowEachWay() {
    let sky = SkyColors.of(.day)
    let small = meadow(.day).filter { $0.w == 3 && $0.h == 3 && $0.y < 200 - 6 }
    // Below the edge at 84 every other cell keeps the top color; above it every fourth takes the middle one.
    #expect(small.filter { $0.y == 84 && $0.color == sky.top }.count == 60)
    #expect(small.filter { $0.y == 81 && $0.color == sky.middle }.count == 30)
    #expect(small.allSatisfy { [81, 84, 144, 147].contains($0.y) })
}

@Test func starsAndMoonOnlyAtNight() {
    func hasStarColor(_ time: SkyTime) -> Bool { meadow(time).contains { $0.color == 0xFFF3C4 } }
    #expect(!hasStarColor(.day))
    #expect(hasStarColor(.night))
}

@Test func sameSeedSameMeadow() {
    #expect(meadow(.day) == meadow(.day))
    #expect(meadow(.day, seed: 7) != meadow(.day, seed: 8))
    #expect(meadow(.night, seed: 7) != meadow(.night, seed: 8))
}

@Test func grassStartsAtTheGround() {
    let sky = SkyColors.of(.day)
    let cells = meadow(.day)
    #expect(cells.contains { $0.color == sky.grass })
    #expect(cells.filter { $0.color == sky.grass }.allSatisfy { $0.y >= 200 })
}

@Test func theMoonStandsWhereTheHomeScreenPutsIt() {
    // Night, 360 wide, ground 200: the moon's top-left is the snapped (0.58 × 360, 0.3 × 200) = (210, 60).
    let moon = meadowCells(width: 360, height: 236, ground: 200, cell: 3, time: .night, moon: CGPoint(x: 0.58, y: 0.3))
        .filter { $0.color == 0xFFF3C4 && $0.opacity == 0.95 }
    #expect(moon.map(\.x).min() == 210 && moon.map(\.y).min() == 60)
    // Moved down under a long name, the whole moon moves with it.
    let lower = meadowCells(width: 360, height: 236, ground: 200, cell: 3, time: .night, moon: CGPoint(x: 0.58, y: 0.4))
        .filter { $0.color == 0xFFF3C4 && $0.opacity == 0.95 }
    #expect(lower.map(\.y).min() == 81)
    #expect(lower.count == moon.count)
}

@Test func cloudsOnlyByDayAndOnlyOnATallMeadow() {
    #expect(meadow(.day).contains { $0.opacity == 0.82 })
    #expect(!meadow(.night).contains { $0.opacity == 0.82 })
    #expect(!meadowCells(width: 360, height: 60, ground: 50, cell: 3, time: .day).contains { $0.opacity == 0.82 })
}
