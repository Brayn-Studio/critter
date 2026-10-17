import Foundation
import Testing
@testable import ClawdCore

@Test func takeCountsWholeTicksAndKeepsThePhase() {
    var grid = TickGrid(tickMs: 60, start: 100)
    #expect(grid.take(now: 100.05) == 0)
    #expect(grid.take(now: 100.15) == 2)
    #expect(abs(grid.lastTick - 100.12) < 1e-9)
    // Taken ticks are gone: asking again at the same moment yields nothing.
    #expect(grid.take(now: 100.15) == 0)
    #expect(grid.take(now: 100.18) == 1)
}

@Test func aWakeRightOnTheGridLineCountsItsTick() {
    var grid = TickGrid(tickMs: 60, start: 0)
    #expect(grid.take(now: 0.0599) == 1)
}

@Test func aLongStallIsCappedAndResyncs() {
    var grid = TickGrid(tickMs: 60, start: 0)
    #expect(grid.take(now: 3600) == TickGrid.maxCatchUpTicks)
    #expect(grid.lastTick == 3600)
}

@Test func dueIsClampedToOneThroughMaxSleepTicks() {
    let grid = TickGrid(tickMs: 60, start: 10)
    #expect(abs(grid.due(afterTicks: 5) - 10.3) < 1e-9)
    #expect(abs(grid.due(afterTicks: 0) - 10.06) < 1e-9)
    #expect(abs(grid.due(afterTicks: Int(Int32.max)) - (10 + 60)) < 1e-9)
}

/// Regression (batch D review): an animation started after the clock slept through a quiet
/// spell must start at "now". Catching up first means the next wake steps it by one tick,
/// not by the whole spell.
@Test func catchingUpBeforeAChangeKeepsTheNewAnimationFromSkippingAhead() {
    var grid = TickGrid(tickMs: 60, start: 0)
    // Quiet: the clock sleeps 40 ticks; a hide arrives 20.5 ticks in.
    let arrival = 20.5 * 0.06
    #expect(grid.take(now: arrival) == 20)          // catch up before starting the vanish
    let wake = grid.due(afterTicks: 1)              // the vanish changes the picture next tick
    #expect(wake > arrival)
    #expect(grid.take(now: wake) == 1)

    // Without catching up the first wake would have stepped the new clip 21 ticks at once.
    var stale = TickGrid(tickMs: 60, start: 0)
    #expect(stale.take(now: stale.due(afterTicks: 1) + 20 * 0.06) == 21)
}
