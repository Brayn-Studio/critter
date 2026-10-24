import Testing
@testable import CritterKit

private func sprig() -> MotionActor {
    MotionActor(skin: SkinLoader.builtin(), rng: MotionRNG(seed: 7))
}

@Test func sleepNowDozesAtOnceWhenIdle() {
    let a = sprig()
    a.enterState(.idle, quiet: true)
    a.sleepNow()
    #expect(a.asleep)
    #expect(!a.isPlayingOnce, "no doze-off clip")
    a.wake()
    #expect(!a.asleep)
}

@Test func sleepNowDoesNothingOutsideIdle() {
    let a = sprig()
    a.enterState(.running, quiet: true)
    a.sleepNow()
    #expect(!a.asleep)
}

/// A sleeping Critter's clock wakes only when the picture changes: the snoring pose every 26 ticks and the floating
/// z, which keeps its cell for a few ticks. Over 30 s (500 ticks of 60 ms) that is well under one wake in two ticks.
@Test func aSleepingCritterWakesTheClockOnFewTicks() {
    let a = sprig()
    a.enterState(.idle, quiet: true)
    a.sleepNow()
    var ticks = 0
    var wakes = 0
    while ticks < 500 {
        let n = max(1, min(a.ticksUntilChange(), TickGrid.maxSleepTicks))
        for _ in 0..<n { a.step() }
        ticks += n
        wakes += 1
    }
    #expect(wakes < 250, "\(wakes) wakes in 500 ticks")
}
