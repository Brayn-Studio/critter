import CoreGraphics
import Foundation
import Testing
@testable import CritterClient

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let fifteenMinutes: TimeInterval = 15 * 60

@Test func dimsToSixtyPercentAfterFifteenIdleMinutes() {
    #expect(BoardScreen.brightness(base: 0.3, idleSince: now, lastTouch: nil, now: now) == 0.3)
    let almost = now.addingTimeInterval(-(fifteenMinutes - 0.001))
    #expect(BoardScreen.brightness(base: 0.3, idleSince: almost, lastTouch: nil, now: now) == 0.3)
    let exactly = now.addingTimeInterval(-fifteenMinutes)
    #expect(abs(BoardScreen.brightness(base: 0.3, idleSince: exactly, lastTouch: nil, now: now) - 0.18) <= 0.0001)
}

/// Idle is counted from the later of the last change and the last touch.
@Test func aTouchOrAChangeKeepsTheBoardBright() {
    let long = now.addingTimeInterval(-2 * fifteenMinutes)
    let recent = now.addingTimeInterval(-60)
    #expect(BoardScreen.brightness(base: 0.5, idleSince: long, lastTouch: recent, now: now) == 0.5)
    #expect(BoardScreen.brightness(base: 0.5, idleSince: recent, lastTouch: long, now: now) == 0.5)
    #expect(abs(BoardScreen.brightness(base: 0.5, idleSince: long, lastTouch: long, now: now) - 0.3) <= 0.0001)
    #expect(abs(BoardScreen.brightness(base: 0.5, idleSince: nil, lastTouch: long, now: now) - 0.3) <= 0.0001)
    // Nothing known yet: not idle.
    #expect(BoardScreen.brightness(base: 0.5, idleSince: nil, lastTouch: nil, now: now) == 0.5)
}

@Test func aTouchAfterTheLastTickMeansNotIdle() {
    // The clock lags the touch by up to a minute, so idle time can be negative.
    #expect(BoardScreen.brightness(base: 0.5, idleSince: nil, lastTouch: now.addingTimeInterval(30), now: now) == 0.5)
}

@Test func brightnessNeverReachesZero() {
    let long = now.addingTimeInterval(-fifteenMinutes)
    #expect(BoardScreen.brightness(base: 0.1, idleSince: long, lastTouch: nil, now: now) > 0)
    #expect(BoardScreen.brightness(base: 0, idleSince: nil, lastTouch: nil, now: now) > 0)
    #expect(BoardScreen.brightness(base: 2, idleSince: nil, lastTouch: nil, now: now) == 1)
}

@Test func shiftStaysWithinFourPt() {
    for seed in 0..<500 {
        let shift = BoardScreen.shift(seed: seed)
        #expect((-4...4).contains(shift.width) && (-4...4).contains(shift.height), "seed \(seed): \(shift)")
        #expect(shift.width == shift.width.rounded() && shift.height == shift.height.rounded(), "whole points")
    }
    // The same seed always gives the same shift, and the seeds do not all give one.
    #expect(BoardScreen.shift(seed: 42) == BoardScreen.shift(seed: 42))
    #expect(Set((0..<50).map { "\(BoardScreen.shift(seed: $0))" }).count > 5)
}

@Test func shiftChangesEveryThreeMinutes() {
    let start = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 180))
    #expect(BoardScreen.shiftSeed(at: start) == BoardScreen.shiftSeed(at: start.addingTimeInterval(179)))
    #expect(BoardScreen.shiftSeed(at: start) != BoardScreen.shiftSeed(at: start.addingTimeInterval(180)))
    #expect(BoardScreen.shiftSeed(at: start.addingTimeInterval(180)) == BoardScreen.shiftSeed(at: start.addingTimeInterval(359)))
}

@Test func clockAndDateReadLikeTheMockup() throws {
    let zone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let sunday = try #require(calendar.date(from: DateComponents(year: 2025, month: 10, day: 19, hour: 22, minute: 12)))
    #expect(BoardScreen.clockText(sunday, timeZone: zone) == "22:12")
    #expect(BoardScreen.dateText(sunday, timeZone: zone) == "10 月 19 日 星期日")
    let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 7, minute: 5)))
    #expect(BoardScreen.clockText(morning, timeZone: zone) == "07:05")
    #expect(BoardScreen.dateText(morning, timeZone: zone) == "3 月 2 日 星期一")
}

/// Whichever way the board is left, the screen goes back to how it was before the board: the brightness saved on
/// the way in, and the screen free to time out again.
@Test func everyWayOutRestoresTheScreen() {
    let saved = ScreenState(brightness: 0.62, idleTimerDisabled: false)
    let exits = BoardScreen.Exit.allCases
    #expect(Set(exits) == [.closeButton, .unplugged, .upright, .inactive, .background, .terminated])
    for exit in exits {
        let restored = BoardScreen.restore(saved: saved, on: exit)
        #expect(restored.brightness == 0.62, "\(exit)")
        #expect(!restored.idleTimerDisabled, "\(exit)")
    }
    // Even if the saved state had the screen kept on (the phone's own setting was on), leaving the board hands
    // back what was saved for the brightness but never leaves the board's keep-awake behind.
    let dimmedAndAwake = ScreenState(brightness: 0.2, idleTimerDisabled: true)
    for exit in exits {
        #expect(!BoardScreen.restore(saved: dimmedAndAwake, on: exit).idleTimerDisabled, "\(exit)")
    }
}

// MARK: - An automatic close waits for the answer card

@Test func anAutomaticCloseWithNoCardOpenIsDoneAtOnce() {
    var hold = BoardCloseHold()
    let now = hold.close(.unplugged)
    #expect(now)
    #expect(hold.held == nil)
    let release = hold.cardOpen(false, reasonNow: .unplugged)
    #expect(release == .none)
}

/// The card and what is typed in it do not go with the board: the close is done once the card closes, if the charger
/// is still out (or the phone still upright).
@Test func anAutomaticCloseWaitsForTheCardAndIsDoneWhenItCloses() {
    var hold = BoardCloseHold()
    let opened = hold.cardOpen(true, reasonNow: nil)
    #expect(opened == .none)
    let first = hold.close(.unplugged)
    #expect(!first)
    #expect(hold.held == .unplugged)
    // The trigger may decide again meanwhile (upright another 3 s): still one close, waiting.
    let second = hold.close(.upright)
    #expect(!second)
    let release = hold.cardOpen(false, reasonNow: .upright)
    #expect(release == .close(.upright))
    #expect(hold.held == nil)
    // Done once: closing nothing again does nothing.
    let again = hold.cardOpen(false, reasonNow: .upright)
    #expect(again == .none)
}

/// Plugged in again and lying in landscape by the time the card closes: no reason holds, the board stays.
@Test func aHeldCloseWhoseReasonIsGoneIsCalledOff() {
    var hold = BoardCloseHold()
    _ = hold.cardOpen(true, reasonNow: nil)
    let held = hold.close(.unplugged)
    #expect(!held)
    let release = hold.cardOpen(false, reasonNow: nil)
    #expect(release == .calledOff)
    #expect(hold.held == nil)
    // A card opened again holds the next close afresh.
    _ = hold.cardOpen(true, reasonNow: nil)
    let heldAgain = hold.close(.unplugged)
    #expect(!heldAgain)
    let releaseAgain = hold.cardOpen(false, reasonNow: .unplugged)
    #expect(releaseAgain == .close(.unplugged))
}

/// Closed by hand (or any other way) while a close was held: the card goes with the board, nothing is left to do.
@Test func aBoardThatWentForgetsItsHeldClose() {
    var hold = BoardCloseHold()
    _ = hold.cardOpen(true, reasonNow: nil)
    _ = hold.close(.upright)
    hold.boardGone()
    let release = hold.cardOpen(false, reasonNow: .upright)
    #expect(release == .none)
}

/// The card over the board goes with it: the next board's automatic close is not held by a card that is not there
/// (its close event never comes, since the card was dropped with the board).
@Test func aBoardThatWentForgetsItsCard() {
    var hold = BoardCloseHold()
    _ = hold.cardOpen(true, reasonNow: nil)
    hold.boardGone()
    #expect(!hold.cardIsOpen)
    let now = hold.close(.unplugged)
    #expect(now)
    #expect(hold.held == nil)
}
