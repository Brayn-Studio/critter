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
    let exits: [BoardScreen.Exit] = [.closeButton, .unplugged, .upright, .background, .terminated]
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
