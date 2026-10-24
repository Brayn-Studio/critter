import Testing
@testable import CritterKit

private typealias Pose = BoardTrigger.Pose

private let open = BoardTrigger.Action.open
private let close = BoardTrigger.Action.close
private let none = BoardTrigger.Action.none
private let blocked = BoardTrigger.Action.blocked

private let landscape = Pose.landscape
private let upright = Pose.upright
private let flat = Pose.other

private func shownTrigger() -> BoardTrigger {
    let t = BoardTrigger()
    _ = t.onPower(charging: true, nowMs: 0)
    t.onBoardShown(true)
    return t
}

/// Every reading in `times`, a gravity reading on the 200 ms beat and the trigger's own tick in between.
private func firstOpen(_ t: BoardTrigger, times: StrideThrough<Int64>) -> Int64? {
    var openedAt: Int64?
    for now in times {
        let action: BoardTrigger.Action
        if now % 200 == 0 {
            action = t.onGravity(x: 9.7, y: 0.3, z: 1.0, nowMs: now)
        } else if (t.nextDeadline() ?? .max) <= now {
            action = t.onTick(nowMs: now)
        } else {
            action = none
        }
        if action == open && openedAt == nil { openedAt = now }
    }
    return openedAt
}

@Test func opensAfterHoldWhileChargingAndLandscape() {
    let t = BoardTrigger()
    #expect(t.onPower(charging: true, nowMs: 0) == none)
    #expect(t.onOrientation(pose: landscape, still: true, nowMs: 0) == none)
    #expect(t.onOrientation(pose: landscape, still: true, nowMs: 2_900) == none)
    #expect(t.nextDeadline() == 3_000)
    #expect(t.onTick(nowMs: 3_000) == open)
    t.onBoardShown(true)
    // Not asked again for the same hold.
    #expect(t.onOrientation(pose: landscape, still: true, nowMs: 3_500) == none)
}

@Test func movingResetsTheHold() {
    let t = BoardTrigger()
    _ = t.onPower(charging: true, nowMs: 0)
    _ = t.onOrientation(pose: landscape, still: true, nowMs: 0)
    _ = t.onOrientation(pose: landscape, still: false, nowMs: 2_000)
    #expect(t.nextDeadline() == nil)
    _ = t.onOrientation(pose: landscape, still: true, nowMs: 2_500)
    #expect(t.onOrientation(pose: landscape, still: true, nowMs: 5_000) == none)
    #expect(t.onOrientation(pose: landscape, still: true, nowMs: 5_500) == open)
}

@Test func doesNotOpenWhenNotCharging() {
    let t = BoardTrigger()
    #expect(t.onOrientation(pose: landscape, still: true, nowMs: 0) == none)
    #expect(t.onOrientation(pose: landscape, still: true, nowMs: 10_000) == none)
    #expect(t.onTick(nowMs: 20_000) == none)
    #expect(t.nextDeadline() == nil)
}

@Test func doesNotOpenWhenSwitchedOff() {
    let t = BoardTrigger()
    t.autoOpen = false
    _ = t.onPower(charging: true, nowMs: 0)
    #expect(!t.sensorWanted)
    _ = t.onOrientation(pose: landscape, still: true, nowMs: 0)
    #expect(t.onOrientation(pose: landscape, still: true, nowMs: 5_000) == none)
    #expect(t.nextDeadline() == nil)
    // A board opened by hand still closes when stood upright, so the sensor runs while it is up.
    t.onBoardShown(true)
    #expect(t.sensorWanted)
    _ = t.onOrientation(pose: upright, still: true, nowMs: 6_000)
    #expect(t.onTick(nowMs: 9_000) == close)
}

@Test func switchingOffDuringTheHoldForgetsIt() {
    let t = BoardTrigger()
    _ = t.onPower(charging: true, nowMs: 0)
    _ = t.onOrientation(pose: landscape, still: true, nowMs: 0)
    #expect(t.nextDeadline() == 3_000)
    t.autoOpen = false
    // Nothing is due any more: an open that can no longer happen keeps no deadline alive.
    #expect(t.nextDeadline() == nil)
    #expect(t.onTick(nowMs: 3_000) == none)
    #expect(t.nextDeadline() == nil)
    // Switched on again, the hold starts afresh from the next still reading.
    t.autoOpen = true
    _ = t.onOrientation(pose: landscape, still: true, nowMs: 4_000)
    #expect(t.nextDeadline() == 7_000)
    #expect(t.onTick(nowMs: 7_000) == open)
}

@Test func brieflyUprightDoesNotExit() {
    let t = shownTrigger()
    #expect(t.onOrientation(pose: upright, still: true, nowMs: 1_000) == none)
    #expect(t.onOrientation(pose: landscape, still: true, nowMs: 3_000) == none) // 2 s upright, then back
    #expect(t.nextDeadline() == nil)
    #expect(t.onTick(nowMs: 10_000) == none)
    #expect(t.onOrientation(pose: upright, still: true, nowMs: 11_000) == none)
    #expect(t.onOrientation(pose: landscape, still: true, nowMs: 13_900) == none)
}

@Test func uprightForThreeSecondsExits() {
    let t = shownTrigger()
    #expect(t.onOrientation(pose: upright, still: true, nowMs: 1_000) == none)
    #expect(t.nextDeadline() == 4_000)
    #expect(t.onTick(nowMs: 3_999) == none)
    #expect(t.onTick(nowMs: 4_000) == close)
}

/// Ruling P3-R4: only standing it up closes the board; flat on a desk or a charging pad does not.
@Test func lyingFlatDoesNotExit() {
    let t = shownTrigger()
    #expect(t.onOrientation(pose: flat, still: true, nowMs: 1_000) == none)
    #expect(t.nextDeadline() == nil)
    #expect(t.onOrientation(pose: flat, still: true, nowMs: 30_000) == none)
    #expect(t.onTick(nowMs: 60_000) == none)
    // Upright after lying flat: the 3 s start from standing up.
    #expect(t.onOrientation(pose: upright, still: true, nowMs: 61_000) == none)
    #expect(t.onTick(nowMs: 63_999) == none)
    #expect(t.onTick(nowMs: 64_000) == close)
}

@Test func lyingFlatDoesNotOpen() {
    let t = BoardTrigger()
    _ = t.onPower(charging: true, nowMs: 0)
    _ = t.onOrientation(pose: flat, still: true, nowMs: 0)
    #expect(t.onOrientation(pose: flat, still: true, nowMs: 5_000) == none)
    #expect(t.nextDeadline() == nil)
}

@Test func unplugExitsAfterTenSeconds() {
    let t = shownTrigger()
    #expect(t.onPower(charging: false, nowMs: 5_000) == none)
    #expect(t.nextDeadline() == 15_000)
    #expect(t.onTick(nowMs: 14_999) == none)
    #expect(t.onTick(nowMs: 15_000) == close)
}

@Test func replugWithinTenSecondsKeepsBoard() {
    let t = shownTrigger()
    _ = t.onPower(charging: false, nowMs: 5_000)
    #expect(t.onPower(charging: true, nowMs: 12_000) == none)
    #expect(t.nextDeadline() == nil)
    #expect(t.onTick(nowMs: 30_000) == none)
}

@Test func manualExitSuppressesUntilReplug() {
    let t = shownTrigger()
    t.onManualExit(nowMs: 1_000)
    t.onBoardShown(false)
    #expect(!t.sensorWanted)
    _ = t.onOrientation(pose: landscape, still: true, nowMs: 2_000)
    #expect(t.onOrientation(pose: landscape, still: true, nowMs: 20_000) == none)
    #expect(t.nextDeadline() == nil)
    // Unplug and plug in again: automatic opening is back.
    _ = t.onPower(charging: false, nowMs: 21_000)
    _ = t.onPower(charging: true, nowMs: 25_000)
    _ = t.onOrientation(pose: landscape, still: true, nowMs: 25_000)
    #expect(t.onOrientation(pose: landscape, still: true, nowMs: 28_000) == open)
}

/// The screen switched off over a board: it stays up (not re-opened, no screen lit), and nothing opens in the dark.
@Test func screenOffDoesNotReopen() {
    let t = BoardTrigger()
    _ = t.onPower(charging: true, nowMs: 0)
    _ = t.onOrientation(pose: landscape, still: true, nowMs: 0)
    #expect(t.onTick(nowMs: 3_000) == open)
    t.onBoardShown(true)

    #expect(t.onScreen(on: false, nowMs: 5_000) == none)
    #expect(!t.sensorWanted)
    #expect(t.nextDeadline() == nil)
    // Readings that still trickle in (a wake-up, a batch) change nothing while the screen is off.
    #expect(t.onOrientation(pose: landscape, still: true, nowMs: 6_000) == none)
    #expect(t.onOrientation(pose: landscape, still: true, nowMs: 9_500) == none)
    #expect(t.onTick(nowMs: 20_000) == none)

    // Even with the board gone, the dark screen is never lit by an opening.
    t.onBoardShown(false)
    #expect(t.onOrientation(pose: landscape, still: true, nowMs: 21_000) == none)
    #expect(t.onOrientation(pose: landscape, still: true, nowMs: 25_000) == none)
    #expect(t.nextDeadline() == nil)

    // Back on: a fresh 3 s hold first.
    #expect(t.onScreen(on: true, nowMs: 30_000) == none)
    #expect(t.sensorWanted)
    #expect(t.onOrientation(pose: landscape, still: true, nowMs: 30_500) == none)
    #expect(t.onTick(nowMs: 33_000) == none)
    #expect(t.onTick(nowMs: 33_500) == open)
}

@Test func screenOffForgetsAHoldInProgress() {
    let t = BoardTrigger()
    _ = t.onPower(charging: true, nowMs: 0)
    _ = t.onOrientation(pose: landscape, still: true, nowMs: 0)
    _ = t.onScreen(on: false, nowMs: 2_000)
    #expect(t.nextDeadline() == nil)
    #expect(t.onTick(nowMs: 3_000) == none)
}

/// Pulling the charger while the board's screen is off still takes the board away 10 s later.
@Test func unplugWhileHiddenStillCloses() {
    let t = shownTrigger()
    _ = t.onScreen(on: false, nowMs: 1_000)
    #expect(t.onPower(charging: false, nowMs: 5_000) == none)
    #expect(t.nextDeadline() == 15_000)
    #expect(t.onTick(nowMs: 14_999) == none)
    #expect(t.onTick(nowMs: 15_000) == close)
}

/// Asked to open, and nothing came up within 2 s: no more asking until the next plug-in.
@Test func openThatNeverShowsBacksOffUntilReplug() {
    let t = BoardTrigger()
    _ = t.onPower(charging: true, nowMs: 0)
    _ = t.onOrientation(pose: landscape, still: true, nowMs: 0)
    #expect(t.onTick(nowMs: 3_000) == open)
    #expect(t.nextDeadline() == 5_000)
    #expect(t.onTick(nowMs: 5_000) == blocked)
    #expect(!t.sensorWanted)
    _ = t.onOrientation(pose: landscape, still: true, nowMs: 5_500)
    #expect(t.onOrientation(pose: landscape, still: true, nowMs: 9_000) == none)
    #expect(t.nextDeadline() == nil)

    _ = t.onPower(charging: false, nowMs: 10_000)
    _ = t.onPower(charging: true, nowMs: 11_000)
    _ = t.onOrientation(pose: landscape, still: true, nowMs: 11_000)
    #expect(t.onTick(nowMs: 14_000) == open)
}

/// The 2 s tick after an opening the system never showed says so, once; the ticks after it are quiet.
@Test func openThatNeverShowsReportsBlocked() {
    let t = BoardTrigger()
    _ = t.onPower(charging: true, nowMs: 0)
    _ = t.onOrientation(pose: landscape, still: true, nowMs: 0)
    #expect(t.onTick(nowMs: 3_000) == open)
    #expect(t.onTick(nowMs: 4_900) == none)
    #expect(t.onTick(nowMs: 5_000) == blocked)
    #expect(t.onTick(nowMs: 5_100) == none)
    #expect(t.onOrientation(pose: landscape, still: true, nowMs: 6_000) == none)
    #expect(t.nextDeadline() == nil)
}

@Test func openThatFailsOutrightReportsBlocked() {
    let t = BoardTrigger()
    _ = t.onPower(charging: true, nowMs: 0)
    _ = t.onOrientation(pose: landscape, still: true, nowMs: 0)
    #expect(t.onTick(nowMs: 3_000) == open)
    #expect(t.onOpenFailed() == blocked)
    #expect(t.onTick(nowMs: 5_000) == none)
}

@Test func openThatShowsInTimeIsNotSuppressed() {
    let t = BoardTrigger()
    _ = t.onPower(charging: true, nowMs: 0)
    _ = t.onOrientation(pose: landscape, still: true, nowMs: 0)
    #expect(t.onTick(nowMs: 3_000) == open)
    t.onBoardShown(true)
    #expect(t.nextDeadline() == nil)
    #expect(t.onTick(nowMs: 5_000) == none)
    // Closed by the trigger (stood up), then laid down again: it opens again on this charge.
    _ = t.onOrientation(pose: upright, still: true, nowMs: 6_000)
    #expect(t.onTick(nowMs: 9_000) == close)
    t.onBoardShown(false)
    _ = t.onOrientation(pose: landscape, still: true, nowMs: 10_000)
    #expect(t.onTick(nowMs: 13_000) == open)
}

@Test func openThatFailsOutrightBacksOffUntilReplug() {
    let t = BoardTrigger()
    _ = t.onPower(charging: true, nowMs: 0)
    _ = t.onOrientation(pose: landscape, still: true, nowMs: 0)
    #expect(t.onTick(nowMs: 3_000) == open)
    _ = t.onOpenFailed()
    #expect(t.nextDeadline() == nil)
    _ = t.onOrientation(pose: landscape, still: true, nowMs: 4_000)
    #expect(t.onTick(nowMs: 10_000) == none)
}

/// From the Open until its board comes up: that board opened by itself.
@Test func awaitingOpenFromTheOpenUntilTheBoardComesUp() {
    let t = BoardTrigger()
    _ = t.onPower(charging: true, nowMs: 0)
    _ = t.onOrientation(pose: landscape, still: true, nowMs: 0)
    #expect(!t.awaitingOpen)
    #expect(t.onTick(nowMs: 3_000) == open)
    #expect(t.awaitingOpen)
    t.onBoardShown(true)
    #expect(!t.awaitingOpen)
}

/// Pulled within the 2 s: a board the user opens by hand later is not the one that was asked for.
@Test func awaitingOpenEndsWhenTheChargerIsPulled() {
    let t = BoardTrigger()
    _ = t.onPower(charging: true, nowMs: 0)
    _ = t.onOrientation(pose: landscape, still: true, nowMs: 0)
    #expect(t.onTick(nowMs: 3_000) == open)
    #expect(t.onPower(charging: false, nowMs: 4_000) == none)
    #expect(!t.awaitingOpen)
    #expect(t.nextDeadline() == nil)
}

@Test func awaitingOpenEndsWhenTheOpenIsGivenUp() {
    let timedOut = BoardTrigger()
    _ = timedOut.onPower(charging: true, nowMs: 0)
    _ = timedOut.onOrientation(pose: landscape, still: true, nowMs: 0)
    #expect(timedOut.onTick(nowMs: 3_000) == open)
    #expect(timedOut.onTick(nowMs: 5_000) == blocked)
    #expect(!timedOut.awaitingOpen)

    let failed = BoardTrigger()
    _ = failed.onPower(charging: true, nowMs: 0)
    _ = failed.onOrientation(pose: landscape, still: true, nowMs: 0)
    #expect(failed.onTick(nowMs: 3_000) == open)
    _ = failed.onOpenFailed()
    #expect(!failed.awaitingOpen)
}

/// A board opened by hand was never asked for.
@Test func aBoardOpenedByHandWasNotAwaited() {
    let t = BoardTrigger()
    _ = t.onPower(charging: true, nowMs: 0)
    #expect(!t.awaitingOpen)
    t.onBoardShown(true)
    #expect(!t.awaitingOpen)
}

@Test func sensorWantedOnlyWhileChargingWithTheScreenOn() {
    let t = BoardTrigger()
    #expect(!t.sensorWanted)
    _ = t.onPower(charging: true, nowMs: 0)
    #expect(t.sensorWanted)
    _ = t.onScreen(on: false, nowMs: 1)
    #expect(!t.sensorWanted)
    _ = t.onScreen(on: true, nowMs: 2)
    #expect(t.sensorWanted)
    _ = t.onPower(charging: false, nowMs: 3)
    #expect(!t.sensorWanted)
}

@Test func posesFromGravity() {
    #expect(BoardTrigger.poseOf(gx: 9.7, gy: 0.5, gz: 1.0) == landscape)
    #expect(BoardTrigger.poseOf(gx: -9.7, gy: 0.5, gz: 1.0) == landscape)
    #expect(BoardTrigger.poseOf(gx: 0.3, gy: 0.5, gz: 9.8) == flat) // flat on the table
    #expect(BoardTrigger.poseOf(gx: 0.3, gy: 9.8, gz: 1.0) == upright) // held upright
    #expect(BoardTrigger.poseOf(gx: 0.3, gy: -9.8, gz: 1.0) == upright) // upside down
    #expect(BoardTrigger.poseOf(gx: 7.5, gy: 0, gz: 6.5) == flat) // propped back too far
    #expect(BoardTrigger.poseOf(gx: 5, gy: 5, gz: 6.5) == flat) // in between
}

@Test func stillMeansNoAxisMovedHalfAUnitInOneAndAHalfSeconds() {
    let s = BoardTrigger.Stillness()
    #expect(!s.add(nowMs: 0, x: 9.7, y: 0, z: 1))
    #expect(s.add(nowMs: 1_500, x: 9.8, y: 0.1, z: 1.2))
    #expect(!s.add(nowMs: 2_000, x: 9.0, y: 0.1, z: 1.2))
    // The reading at 1.5 s held until the jolt at 2 s: still in the window at 3.4 s, gone from it at 3.5 s.
    #expect(!s.add(nowMs: 3_400, x: 9.0, y: 0.1, z: 1.2))
    #expect(s.add(nowMs: 3_500, x: 9.0, y: 0.1, z: 1.2))
}

/// One reading says nothing about movement: the phone may be swinging through landscape.
@Test func oneReadingIsNotStill() {
    #expect(!BoardTrigger.Stillness().add(nowMs: 10_000, x: 9.7, y: 0, z: 1))
    let s = BoardTrigger.Stillness()
    _ = s.add(nowMs: 0, x: 9.7, y: 0, z: 1)
    s.clear()
    #expect(!s.add(nowMs: 5_000, x: 9.7, y: 0, z: 1), "cleared: a fresh start")
}

/// Still since the first of the readings that showed it, not since the window was first full.
@Test func stillSinceIsWhereTheStillReadingsBegin() {
    let s = BoardTrigger.Stillness()
    for t in stride(from: Int64(0), through: 1_400, by: 200) { _ = s.add(nowMs: t, x: 9.7, y: 0, z: 1) }
    #expect(s.stillSince == nil)
    #expect(s.add(nowMs: 1_600, x: 9.7, y: 0, z: 1))
    #expect(s.stillSince == 0)
    #expect(s.add(nowMs: 5_000, x: 9.7, y: 0, z: 1))
    #expect(s.stillSince == 0, "the same still spell")
    #expect(!s.add(nowMs: 5_200, x: 5, y: 5, z: 5))
    #expect(s.stillSince == nil)
}

/// Design §8.6: charging, landscape and still for 3 s opens the board. Real readings every 200 ms from 0: the
/// 1.5 s it takes to see the phone is still are part of those 3 s, not added to them.
@Test func gravityReadingsOpenTheBoardAfterThreeSeconds() {
    let t = BoardTrigger()
    _ = t.onPower(charging: true, nowMs: 0)
    t.onSensorStarted()
    #expect(firstOpen(t, times: stride(from: Int64(0), through: 6_000, by: 100)) == 3_000)
}

/// Readings from before the sensor was started again (the screen was off, say) count for nothing.
@Test func aRestartedSensorStartsTheStillnessAfresh() {
    let t = BoardTrigger()
    _ = t.onPower(charging: true, nowMs: 0)
    t.onSensorStarted()
    for now in stride(from: Int64(0), through: 2_000, by: 200) { _ = t.onGravity(x: 9.7, y: 0.3, z: 1.0, nowMs: now) }
    _ = t.onScreen(on: false, nowMs: 2_100)
    _ = t.onScreen(on: true, nowMs: 10_000)
    t.onSensorStarted()
    #expect(firstOpen(t, times: stride(from: Int64(10_000), through: 16_000, by: 100)) == 13_000)
}

@Test func stillAfterAFullWindow() {
    let s = BoardTrigger.Stillness()
    for t in stride(from: Int64(0), through: 1_400, by: 200) {
        #expect(!s.add(nowMs: t, x: 9.7, y: 0, z: 1), "at \(t) ms the readings cover less than 1.5 s")
    }
    #expect(s.add(nowMs: 1_600, x: 9.7, y: 0, z: 1))
}
