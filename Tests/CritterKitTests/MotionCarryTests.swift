import Testing
@testable import CritterKit

private func sprig(reduceMotion: Bool = false) -> MotionActor {
    MotionActor(skin: SkinLoader.builtin(), rng: MotionRNG(seed: 7), reduceMotion: reduceMotion)
}

@Test func carriedCritterWalksHomeAfterTheDrop() {
    let a = sprig()
    a.carry(dxCells: 10)
    #expect(a.snapshot().offsetX == 10)
    a.walkHome()
    var offsets: [Int] = []
    for _ in 0..<8 {
        a.step()
        let s = a.snapshot()
        offsets.append(s.offsetX)
        if s.offsetX != 0 { #expect(a.skin.interactions.walkLeft.contains(s.pose), "\(s.pose)") }
    }
    #expect(offsets == [8, 6, 5, 4, 3, 2, 1, 0])
    #expect(!a.following)
}

@Test func carryPersistsAcrossTicks() {
    let a = sprig()
    a.setMode(a.skin.interactions.held)
    a.lift = 3
    a.carry(dxCells: 10)
    for tick in 0..<30 {
        a.step()
        #expect(a.snapshot().offsetX == 10, "tick \(tick)")
    }
    #expect(!a.following)
    a.setMode(nil)
    a.walkHome()
    for _ in 0..<8 { a.step() }
    #expect(a.snapshot().offsetX == 0)
}

@Test func reducedMotionSnapsHome() {
    let a = sprig(reduceMotion: true)
    a.carry(dxCells: 10)
    a.walkHome()
    a.step()
    #expect(a.snapshot().offsetX == 0)
    #expect(!a.following)
}
