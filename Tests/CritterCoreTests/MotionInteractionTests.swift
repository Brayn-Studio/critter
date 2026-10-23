import CoreGraphics
import Foundation
import Testing
@testable import CritterCore
@testable import CritterKit

private func makeActor(_ skin: SkinManifest = SkinLoader.builtin(), seed: UInt64 = 7, reduceMotion: Bool = false) -> MotionActor {
    MotionActor(skin: skin, rng: MotionRNG(seed: seed), reduceMotion: reduceMotion)
}

@discardableResult
private func stepUntilLoop(_ a: MotionActor, limit: Int = 500) -> Int {
    var n = 0
    while a.isPlayingOnce && n < limit { a.step(); n += 1 }
    return n
}

private func rows(_ k: MotionClip) -> [[String]] {
    k.map { [$0.pose, "\($0.ticks)", "\($0.dx)", "\($0.dy)", $0.effect ?? ""] }
}

// MARK: - Travel

@Test func travelKeysMatchPreview() {
    let names = SkinLoader.builtin().interactions
    let k = MotionTravel.keys(fromDx: 30, fromDy: 0, toDy: 0, delay: 2, hopLength: 14, names: names)
    #expect(rows(k) == [
        ["base", "2", "30", "0", ""], ["air", "1", "28", "2", ""], ["air", "1", "25", "3", ""], ["air", "1", "23", "2", ""], ["base", "1", "20", "0", ""],
        ["air", "1", "17", "2", ""], ["air", "1", "15", "3", ""], ["air", "1", "12", "2", ""], ["base", "1", "10", "0", ""],
        ["air", "1", "8", "2", ""], ["air", "1", "5", "3", ""], ["air", "1", "3", "2", ""], ["base", "1", "0", "0", ""],
        ["base", "2", "0", "-2", "dust_small"], ["base", "1", "0", "0", ""], ["shut", "1", "0", "0", ""]])
}

@Test func seatKeysEndRaised() {
    let names = SkinLoader.builtin().interactions
    let k = MotionTravel.keys(fromDx: -20, fromDy: 0, toDy: 2, delay: 0, hopLength: 14, names: names)
    #expect(rows(k) == [
        ["air", "1", "-17", "2", ""], ["air", "1", "-15", "4", ""], ["air", "1", "-12", "3", ""], ["base", "1", "-10", "1", ""],
        ["air", "1", "-7", "3", ""], ["air", "1", "-5", "5", ""], ["air", "1", "-2", "4", ""], ["base", "1", "0", "2", ""],
        ["base", "1", "0", "1", "dust_small"], ["base", "1", "0", "2", "@seat"]])
}

@Test func travelCompletesAndClearsTraveling() {
    let a = makeActor()
    a.enterState(.waiting, quiet: true)
    var ok: Bool?
    a.travel(fromDx: 30, fromDy: 0, delay: 2) { ok = $0 }
    #expect(a.traveling)
    #expect(a.snapshot().bodyX == 30)
    #expect(a.snapshot().accessory == nil)
    #expect(a.snapshot().badge == nil)
    #expect(stepUntilLoop(a) == 18)
    #expect(ok == true)
    #expect(!a.traveling)
    #expect(a.currentClipName == "ask")
    #expect(a.snapshot().accessory != nil)
    #expect(a.snapshot().badge != nil)
}

@Test func travelInterruptedCompletesFalse() {
    let a = makeActor()
    var ok: Bool?
    a.travel(fromDx: 30, fromDy: 0, delay: 0) { ok = $0 }
    a.step()
    a.play("blink")
    #expect(ok == false)
    #expect(!a.traveling)
    // a new travel that replaces one in flight stays traveling
    var first: Bool?, second: Bool?
    a.travel(fromDx: 10, fromDy: 0, delay: 0) { first = $0 }
    a.travel(fromDx: 20, fromDy: 0, delay: 0) { second = $0 }
    #expect(first == false)
    #expect(second == nil)
    #expect(a.traveling)
}

@Test func travelReplacedFromACompletionLeavesNoStrayFlags() {
    // travel 1's completion starts another clip while travel 2 is replacing it
    let a = makeActor()
    a.enterState(.done, quiet: true)
    var first: Bool?, second: Bool?
    a.travel(fromDx: 30, fromDy: 0, delay: 0) { [unowned a] ok in
        first = ok
        a.play("blink")
    }
    a.step()
    a.travel(fromDx: -20, fromDy: 0, delay: 0, seat: PileSeating.seat(row: 2)) { second = $0 }
    #expect(first == false)
    #expect(second == false)
    #expect(!a.traveling)
    #expect(a.currentClipName == "blink")
    #expect(a.travelSeat == nil)
    a.reduceMotion = true                      // must not seat it or end the blink
    #expect(a.tint == nil && a.alpha == 1 && a.z == 2)
    #expect(a.currentClipName == "blink")

    // ...or cancels the one-shot
    let b = makeActor()
    var cancelled: Bool?
    b.travel(fromDx: 30, fromDy: 0, delay: 0) { [unowned b] _ in b.cancelOnce() }
    b.travel(fromDx: 10, fromDy: 0, delay: 0) { cancelled = $0 }
    #expect(cancelled == false)
    #expect(!b.traveling)
    #expect(!b.isPlayingOnce)
    #expect(b.currentClipName == "idle")
}

@Test func noBrainWhileTravelingOrFollowing() {
    let a = makeActor()
    a.enterState(.idle, quiet: true)
    let fidgetIn = a.fidgetIn
    a.travel(fromDx: 30, fromDy: 0, delay: 0)
    for _ in 0..<5 { a.step() }
    #expect(a.traveling)
    #expect(a.fidgetIn == fidgetIn)
    #expect(a.idleTicks == 0)
    stepUntilLoop(a)
    a.startFollow(lookLeft: true)
    for _ in 0..<300 { a.step() }
    #expect(a.following)
    #expect(a.fidgetIn == fidgetIn)
    #expect(a.idleTicks == 0)
    #expect(!a.isPlayingOnce)

    let r = makeActor()
    r.enterState(.running, quiet: true)
    r.setActivity("think")
    r.startFollow(lookLeft: false)
    for _ in 0..<100 { r.step() }
    #expect(r.variant == "laptop")
}

@Test func seatAppliesDimAlphaZAtLastKey() {
    let a = makeActor()
    a.enterState(.done, quiet: true)
    a.fidgetIn = 10_000
    var ok: Bool?
    a.travel(fromDx: -20, fromDy: 0, delay: 0, seat: PileSeating.seat(row: 2)) { ok = $0 }
    for _ in 0..<8 { a.step() }
    #expect(a.tint == nil && a.alpha == 1 && a.z == 2)
    a.step()                                   // the last key starts
    #expect(a.tint == .dim)
    #expect(a.alpha == 0.55)
    #expect(a.z == 0)
    #expect(a.traveling)
    a.step()
    #expect(ok == true)
    #expect(!a.traveling)
    for _ in 0..<50 { a.step() }
    #expect(a.snapshot().bodyY == 2)
    #expect(a.snapshot().pose == "base")
    #expect(a.tint == .dim)
}

@Test func unseatRestoresStateLook() {
    let a = makeActor()
    a.enterState(.waiting, quiet: true)
    a.noAccessory = true
    a.travel(fromDx: -20, fromDy: 0, delay: 0, seat: PileSeating.seat(row: 1))
    stepUntilLoop(a)
    #expect(a.tint == .dim && a.alpha == 0.75 && a.z == 1)
    #expect(a.snapshot().bodyY == 1)
    a.unseat()
    #expect(a.tint == nil)
    #expect(a.alpha == 1)
    #expect(a.z == 2)
    #expect(!a.noAccessory)
    #expect(a.currentClipName == "ask")
    #expect(a.snapshot().bodyY == 0)

    let idle = makeActor()
    idle.enterState(.idle, quiet: true)
    idle.travel(fromDx: 8, fromDy: 0, delay: 0, seat: PileSeating.seat(row: 2))
    stepUntilLoop(idle)
    idle.unseat()
    #expect(idle.tint == .dim)                 // idle's own tint
    #expect(idle.alpha == 1)
}

@Test func travelUnderReduceMotionCompletesImmediately() {
    let a = makeActor(reduceMotion: true)
    a.enterState(.waiting, quiet: true)
    var ok: Bool?
    a.travel(fromDx: 30, fromDy: 0, delay: 2, seat: PileSeating.seat(row: 1)) { ok = $0 }
    #expect(ok == true)
    #expect(!a.traveling)
    #expect(!a.isPlayingOnce)
    #expect(a.tint == .dim && a.alpha == 0.75 && a.z == 1)

    var plain: Bool?
    a.travel(fromDx: -12, fromDy: 0, delay: 0) { plain = $0 }
    #expect(plain == true)
    #expect(!a.traveling)
}

@Test func enablingReduceMotionFinishesTravel() {
    let a = makeActor()
    a.enterState(.done, quiet: true)
    var ok: Bool?
    a.travel(fromDx: -20, fromDy: 0, delay: 4, seat: PileSeating.seat(row: 2)) { ok = $0 }
    a.emit("dust")
    for _ in 0..<3 { a.step() }
    #expect(a.traveling)
    #expect(ok == nil)
    a.reduceMotion = true
    #expect(ok == true)
    #expect(!a.traveling)
    #expect(!a.isPlayingOnce)
    #expect(a.tint == .dim && a.alpha == 0.55 && a.z == 0)
    #expect(a.particles.isEmpty)

    let b = makeActor()
    var plain: Bool?
    b.travel(fromDx: 30, fromDy: 0, delay: 0) { plain = $0 }
    b.step()
    b.reduceMotion = true
    #expect(plain == true)
    #expect(!b.traveling)
    #expect(b.tint == .dim)                    // idle's own tint, untouched
    #expect(b.alpha == 1)
}

// MARK: - Follow

@Test func followWalksThenJogs() {
    let a = makeActor()
    a.enterState(.idle, quiet: true)
    a.startFollow(lookLeft: false)
    #expect(a.following)
    a.followShift(dx: 10, dy: 0)
    var s = a.snapshot()
    #expect(s.offsetX == -10)
    #expect(s.pose == "walk_r_b")              // trotting at clock 0
    var xs: [Int] = [], poses: [String] = []
    for _ in 0..<9 {
        a.step()
        s = a.snapshot()
        xs.append(s.offsetX)
        poses.append(s.pose)
        #expect(s.bodyX == 0 && s.bodyY == 0 && s.offsetY == 0)
    }
    #expect(xs == [-8, -6, -5, -4, -3, -2, -1, 0, 0])
    // trotting (|offset| > 6) swaps legs every tick, walking every 2 ticks
    #expect(poses == ["walk_r_a", "walk_r_a", "walk_r_a", "walk_r_b", "walk_r_b", "walk_r_a", "walk_r_a", "look_r", "look_r"])
    #expect(a.following)                       // still held: keeps following

    let b = makeActor()
    b.startFollow(lookLeft: true)
    b.followShift(dx: -3, dy: 0)
    #expect(b.snapshot().offsetX == 3)
    #expect(b.snapshot().pose.hasPrefix("walk_l_"))
}

@Test func followCapsAt12And8() {
    let a = makeActor()
    a.startFollow(lookLeft: true)
    a.followShift(dx: 30, dy: -20)
    #expect(a.snapshot().offsetX == -12)
    #expect(a.snapshot().offsetY == 8)
    a.followShift(dx: -50, dy: 50)
    #expect(a.snapshot().offsetX == 12)
    #expect(a.snapshot().offsetY == -8)
}

@Test func verticalCatchUpHopsAndLandsWithDust() {
    let a = makeActor()
    a.startFollow(lookLeft: true)
    a.followShift(dx: 0, dy: 3)                // the window went up 3 cells
    #expect(a.snapshot().offsetY == -3)
    #expect(a.snapshot().pose == "air")
    a.step()
    a.step()
    #expect(a.snapshot().offsetY == -1)
    #expect(a.snapshot().pose == "air")
    #expect(a.particles.isEmpty)
    a.step()
    #expect(a.snapshot().offsetY == 0)
    #expect(a.snapshot().pose == "look_l")
    #expect(a.particles.count == 2)            // dust_small on landing
}

@Test func followEndsAfterReleaseAndBlinks() {
    let a = makeActor()
    a.enterState(.idle, quiet: true)
    a.startFollow(lookLeft: true)
    a.followShift(dx: 3, dy: 0)
    for _ in 0..<5 { a.step() }
    #expect(a.following)                       // caught up but still held
    #expect(!a.isPlayingOnce)
    a.releaseFollow()
    a.step()
    #expect(!a.following)
    #expect(a.currentClipName == "blink")

    let b = makeActor()
    b.startFollow(lookLeft: true)
    b.followShift(dx: 3, dy: 0)
    b.releaseFollow()
    b.step()
    b.step()
    #expect(b.following)
    b.step()                                   // caught up on this tick
    #expect(!b.following)
    #expect(b.currentClipName == "blink")
}

@Test func reduceMotionFollowStaysPut() {
    let a = makeActor()
    a.startFollow(lookLeft: true)
    a.followShift(dx: 10, dy: 4)
    a.reduceMotion = true
    #expect(a.snapshot().offsetX == 0 && a.snapshot().offsetY == 0)
    a.followShift(dx: 10, dy: 4)
    #expect(a.snapshot().offsetX == 0 && a.snapshot().offsetY == 0)
    #expect(a.snapshot().pose == "base")       // idle's still, not a walk
    a.releaseFollow()
    a.step()
    #expect(!a.following)
    #expect(!a.isPlayingOnce)                  // no blink under reduced motion
}

@Test func followIgnoredWhileTraveling() {
    let a = makeActor()
    a.travel(fromDx: 30, fromDy: 0, delay: 0)
    a.startFollow(lookLeft: true)
    #expect(!a.following)
    a.followShift(dx: 10, dy: 0)
    #expect(a.snapshot().offsetX == 0)
    #expect(a.traveling)

    let h = makeActor()
    h.hidden = true
    h.startFollow(lookLeft: true)
    #expect(!h.following)

    let c = makeActor()
    c.play("wink")
    c.startFollow(lookLeft: true)              // a follower drops what it was doing
    #expect(c.following)
    #expect(!c.isPlayingOnce)
}

@Test func ticksUntilChangeWhileFollowing() {
    let a = makeActor()
    a.enterState(.error, quiet: true)          // slump: a 36-tick key, a still marker
    a.startFollow(lookLeft: true)
    #expect(a.ticksUntilChange() == 36)        // caught up and held: nothing moves
    a.followShift(dx: 2, dy: 0)
    #expect(a.ticksUntilChange() == 1)
    a.step()
    a.step()
    #expect(a.snapshot().offsetX == 0)
    #expect(a.ticksUntilChange() == 34)
    a.releaseFollow()
    #expect(a.ticksUntilChange() == 1)         // ends (and blinks) on the next tick
}

@Test func travelEndsAFollowOnTheSpot() {
    let a = makeActor()
    a.startFollow(lookLeft: true)
    a.followShift(dx: 5, dy: 2)
    #expect(a.followOffset.x == -5 && a.followOffset.y == -2)
    a.travel(fromDx: 20, fromDy: 0, delay: 0)
    #expect(!a.following)
    #expect(a.traveling)
    #expect(a.followOffset.x == 0 && a.followOffset.y == 0)
    #expect(a.snapshot().pose == "air")        // the hop shows, not a walk
    a.releaseFollow()
    stepUntilLoop(a)
    #expect(!a.following)
    #expect(a.currentClipName != "blink")      // no follow left to end with a blink
}

@Test func followOffsetMatchesTheSnapshot() {
    let a = makeActor()
    a.startFollow(lookLeft: false)
    a.followShift(dx: 2.5, dy: -1.5)
    let s = a.snapshot()
    #expect(a.followOffset.x == s.offsetX && a.followOffset.y == s.offsetY)
    #expect(s.offsetX == -2 && s.offsetY == 2)  // jsRound(-2.5) = -2, jsRound(1.5) = 2
}

@Test func hopStartsWhereAFollowerIsDrawn() {
    let a = makeActor()
    a.startFollow(lookLeft: true)
    a.followShift(dx: 5, dy: -2)               // drawn 5 cells left, 2 cells up
    let drawn = a.snapshot()
    #expect(drawn.offsetX == -5 && drawn.offsetY == 2)
    a.travel(fromDx: 20, fromDy: 0, delay: 2)
    let s = a.snapshot()
    #expect(s.offsetX == 0 && s.offsetY == 0)
    #expect(s.bodyX == 15 && s.bodyY == 2)     // the same spot, now as the hop's start
}

// MARK: - Entrances cut short by a hop

private func stepWhileTraveling(_ a: MotionActor, limit: Int = 200) {
    var n = 0
    while a.traveling && n < limit { a.step(); n += 1 }
}

@Test func hopReplaysTheEntranceItCutShort() {
    let a = makeActor()
    a.enterState(.idle, quiet: true)
    a.enterState(.done)
    #expect(a.currentClipName == "celebrate")
    a.step()
    var landed: Bool?
    a.travel(fromDx: 20, fromDy: 0, delay: 0) { landed = $0 }
    stepWhileTraveling(a)
    #expect(landed == true)
    #expect(a.currentClipName == "celebrate")  // the whole entrance, after the hop
    #expect(a.isPlayingOnce)
    stepUntilLoop(a)
    #expect(a.currentClipName == "content")

    // running → done: the hop cuts the laptop's exit; the done entrance plays after it
    let r = makeActor()
    r.enterState(.running, quiet: true)
    r.enterState(.done)
    #expect(r.currentClipName == "lap_close")
    r.travel(fromDx: -14, fromDy: 0, delay: 0)
    stepWhileTraveling(r)
    #expect(r.currentClipName == "celebrate")
}

@Test func hopReplaysTheWaitingAlertWithItsBadge() {
    let a = makeActor()
    a.enterState(.idle, quiet: true)
    a.enterState(.waiting)
    #expect(a.currentClipName == "alert")
    a.travel(fromDx: 14, fromDy: 0, delay: 0)
    #expect(a.snapshot().badge == nil)         // markers hide while hopping
    stepWhileTraveling(a)
    #expect(a.currentClipName == "alert")
    #expect(a.badgeVisible)
    #expect(a.badgeAge == 0)                   // the ! pops up again with the alert
}

@Test func hopLeavesOtherOneShotsAndSeatsAlone() {
    // the entrance was already over: back to the loop
    let done = makeActor()
    done.enterState(.idle, quiet: true)
    done.enterState(.done)
    stepUntilLoop(done)
    done.travel(fromDx: 14, fromDy: 0, delay: 0)
    stepWhileTraveling(done)
    #expect(!done.isPlayingOnce)

    // a fidget is not an entrance
    let idle = makeActor()
    idle.enterState(.idle, quiet: true)
    idle.play("wink")
    idle.travel(fromDx: 14, fromDy: 0, delay: 0)
    stepWhileTraveling(idle)
    #expect(!idle.isPlayingOnce)

    // a hop into a pile seat stays seated
    let seated = makeActor()
    seated.enterState(.idle, quiet: true)
    seated.enterState(.done)
    seated.travel(fromDx: 14, fromDy: 0, delay: 0, seat: PileSeating.seat(row: 1))
    stepWhileTraveling(seated)
    #expect(!seated.isPlayingOnce)
    #expect(seated.snapshot().bodyY == 1)

    // a new state during the hop plays its own entrance instead
    let changed = makeActor()
    changed.enterState(.idle, quiet: true)
    changed.enterState(.done)
    changed.travel(fromDx: 14, fromDy: 0, delay: 0)
    changed.step()
    changed.enterState(.error)
    #expect(changed.currentClipName == "oops")
    #expect(!changed.traveling)
}

@Test func reducedMotionDrawsNoSwing() {
    let held = makeActor(reduceMotion: true)
    held.setMode("held")
    held.lift = 3
    held.lag = -2
    var s = held.snapshot()
    #expect(s.pose == "held_a")
    #expect(s.bodyX == 0 && s.bodyY == 3)      // lifted, but not swung
    held.reduceMotion = false
    #expect(held.snapshot().bodyX == -2)

    let w = makeActor(reduceMotion: true)
    w.enterState(.waiting, quiet: true)
    let still = w.snapshot()
    w.lag = 3
    w.particles = [Particle(glyph: "dot", color: "#B4BAC4", x: 4, y: 0, life: 10)]
    s = w.snapshot()
    #expect(s.bodyX == still.bodyX)
    #expect(s.badge?.x == still.badge?.x && s.accessory?.x == still.accessory?.x)
    #expect(s.particles.first?.x == 4)
}

// MARK: - Gaze

@Test func gazeZones() {
    let c = CGPoint(x: 100, y: 100)
    func zone(_ x: CGFloat, _ y: CGFloat) -> GazeZone? { MotionGaze.zone(pointer: CGPoint(x: x, y: y), center: c, unit: 3) }
    #expect(zone(300, 100) == nil)             // 200 pt away
    #expect(zone(100, 140) == .up)             // 40 above
    #expect(zone(70, 100) == .left)            // 30 left
    #expect(zone(130, 100) == .right)          // 30 right
    #expect(zone(100, 80) == .down)            // 20 below
    #expect(zone(105, 100) == .center)
    #expect(zone(100, 95) == .center)          // only 5 below
    #expect(zone(100, 120) == .center)         // 20 above is not above enough
    #expect(zone(150, 140) == .right)          // above, but more sideways than up
}

@Test func gazeOnlyWhenCalm() {
    let w = makeActor()
    w.enterState(.waiting, quiet: true)
    w.setGaze(.left)
    #expect(w.snapshot().pose == "raise")

    let a = makeActor()
    a.enterState(.idle, quiet: true)
    a.setGaze(.left)
    #expect(a.snapshot().pose == "look_l")
    a.setGaze(.up)
    #expect(a.snapshot().pose == "look_up")
    a.play("blink")
    #expect(a.snapshot().pose == "shut")       // no gaze over a one-shot
    a.cancelOnce()
    a.setMode("pet")
    #expect(a.snapshot().pose == "happy_l")    // nor over a mode
    a.setMode(nil)
    a.setGaze(nil)
    #expect(a.snapshot().pose == "base")

    let d = makeActor()
    d.enterState(.done, quiet: true)
    d.setGaze(.right)
    #expect(d.snapshot().pose == "bloom_r")    // done's own gaze poses keep the flower open

    let r = makeActor(reduceMotion: true)
    r.enterState(.idle, quiet: true)
    r.setGaze(.down)
    #expect(r.snapshot().pose == "look_down")
}

@Test func stateGazePosesReplaceTheLookPoses() throws {
    // Sprig's done state keeps its flower on while it looks around.
    let a = makeActor(try bundledSkin("sprig"))
    a.enterState(.done, quiet: true)
    a.setGaze(.right)
    #expect(a.snapshot().pose == "bloom_r")
    a.setGaze(.center)
    #expect(a.snapshot().pose == "bloom_open")
    // The zone outlasts the state: idle has no gaze of its own, so the plain look poses.
    a.setGaze(.right)
    a.enterState(.idle, quiet: true)
    #expect(a.snapshot().pose == "look_r")
}

// MARK: - Rubbing

@Test func rubNeedsThreeReversalsInOneSecond() {
    var r = RubDetector()
    // x positions at 0.1 s steps: right, left (1), right (2), left (3)
    let rubbing = [0.0, 5, 0, 5, 0].enumerated().map { i, x in r.move(x: x, at: 0.1 * Double(i)) }
    #expect(rubbing == [false, false, false, false, true])

    var slow = RubDetector()
    let slowRubbing = [(0.0, 0.0), (5, 0.1), (0, 0.6), (5, 1.2), (0, 1.8)].map { x, t in slow.move(x: x, at: t) }
    #expect(slowRubbing == [false, false, false, false, false])   // the first reversal is over a second old
}

@Test func rubIgnoresSmallMovesAndEndsAfter700ms() {
    var r = RubDetector()
    let jitter = (0...10).map { i in r.move(x: i % 2 == 0 ? 0 : 2, at: 0.05 * Double(i)) }
    #expect(!jitter.contains(true))
    #expect(!r.shouldEnd(at: 2))               // nothing counted yet

    for (i, x) in [5.0, 0, 5, 0].enumerated() { _ = r.move(x: x, at: 1 + 0.1 * Double(i)) }
    let smallMove = r.move(x: 1, at: 1.35)
    #expect(smallMove)                         // still rubbing
    #expect(!r.shouldEnd(at: 1.95))            // last counted move at 1.3
    #expect(r.shouldEnd(at: 2.01))
    r.reset()
    #expect(!r.shouldEnd(at: 5))
    let afterReset = r.move(x: 40, at: 5)
    #expect(!afterReset)
}

// MARK: - Hover and held swing

@Test func hoverAreaCoversTheBodyColumnsAndAFewPointsBelowTheGround() {
    let o = CGPoint(x: 100, y: 50)
    func on(_ x: CGFloat, _ y: CGFloat, offset: (x: Int, y: Int) = (0, 0), pile: Bool = false) -> Bool {
        MotionHover.contains(pointer: CGPoint(x: x, y: y), anchor: o, unit: 3, offset: offset, pile: pile)
    }
    #expect(on(103, 50))                       // column 1, on the ground
    #expect(!on(102.9, 50))
    #expect(on(151, 50))                       // column 17
    #expect(!on(151.1, 50))
    #expect(on(120, 48))                       // 2 pt below the ground
    #expect(!on(120, 47.9))
    #expect(on(120, 83))                       // 11 cells up
    #expect(!on(120, 83.1))
    // following 4 cells left and 2 down: the area goes along
    #expect(on(145, 50))
    #expect(!on(145, 50, offset: (-4, -2)))
    #expect(on(91, 44, offset: (-4, -2)))
    #expect(!on(91, 41.9, offset: (-4, -2)))
    // the merged pile reaches 1 cell left, 27 right, 13 up
    #expect(on(97, 50, pile: true))
    #expect(!on(96.9, 50, pile: true))
    #expect(on(181, 89, pile: true))
    #expect(!on(181.1, 50, pile: true))
    #expect(!on(120, 89.1, pile: true))
}

@Test func heldSwingTrailsThePointerAndSettles() {
    #expect(MotionDrag.lag(pointerDx: 0) == 0)
    #expect(MotionDrag.lag(pointerDx: 3) == -1)
    #expect(MotionDrag.lag(pointerDx: 4.5) == -1)     // -1.5 rounds up to -1
    #expect(MotionDrag.lag(pointerDx: -4.5) == 2)     // 1.5 rounds up to 2
    #expect(MotionDrag.lag(pointerDx: 7.5) == -2)     // -2.5 → -2 (Math.round)
    #expect(MotionDrag.lag(pointerDx: 40) == -3)
    #expect(MotionDrag.lag(pointerDx: -40) == 3)
    #expect(MotionDrag.settle(3) == 2)
    #expect(MotionDrag.settle(-2) == -1)
    #expect(MotionDrag.settle(0) == 0)
}

// MARK: - Pile seating

@Test func pileSeatsFarthestBackFirst() {
    #expect(PileSeating.seats(departureOrder: ["d", "c", "b", "a"], lead: "b", total: 4) == ["b": 0, "d": 2, "c": 1, "a": 1])
    #expect(PileSeating.seats(departureOrder: ["x", "y"], lead: "y", total: 2) == ["y": 0, "x": 1])
    #expect(PileSeating.backRows(total: 1) == 0)
    #expect(PileSeating.backRows(total: 2) == 1)
    #expect(PileSeating.backRows(total: 7) == 2)
    #expect(PileSeating.seat(row: 2) == Seat(row: 2, alpha: 0.55, z: 0))
    #expect(PileSeating.seat(row: 1) == Seat(row: 1, alpha: 0.75, z: 1))
}

@Test func pileShowsWhoeverACollapseWouldSeatLast() {
    // a → row 2, b, c → row 1 (c covers b).
    #expect(PileSeating.shown(order: ["a", "b", "c"], lead: "l", total: 4, occupants: [:]) == [2: "a", 1: "c"])
    #expect(PileSeating.shown(order: ["a"], lead: "l", total: 2, occupants: [:]) == [1: "a"])
    #expect(PileSeating.shown(order: [], lead: "l", total: 1, occupants: [:]).isEmpty)
}

@Test func pileKeepsTheCollapsesOccupants() {
    #expect(PileSeating.shown(order: ["a", "b", "c"], lead: "l", total: 4, occupants: [2: "c", 1: "a"]) == [2: "c", 1: "a"])
    // An occupant that left (or became the lead) gives its row to someone else behind.
    #expect(PileSeating.shown(order: ["a", "b", "c"], lead: "l", total: 4, occupants: [2: "x", 1: "a"]) == [2: "c", 1: "a"])
}

@Test func pileFillsEveryRowWhileSomeoneIsLeft() {
    // Merged [A, B, C] seated row 2 = B, row 1 = C; then C became the lead: B keeps row 2, and
    // row 1 (whose only seat candidate is B) goes to A rather than to the lead's look.
    #expect(PileSeating.shown(order: ["A", "B"], lead: "C", total: 3, occupants: [2: "B", 1: "C"]) == [2: "B", 1: "A"])
    // Back rows grew from 1 to 2: the old row-1 occupant stays, the new row gets the other.
    #expect(PileSeating.shown(order: ["B", "C"], lead: "A", total: 3, occupants: [1: "B"]) == [1: "B", 2: "C"])
    // Never the same Critter twice.
    let shown = PileSeating.shown(order: ["a", "b"], lead: "l", total: 3, occupants: [1: "a", 2: "a"])
    #expect(Set(shown.values).count == shown.count)
    #expect(shown.count == 2)
}

// MARK: - Under ground

@Test func heldUnderGroundNothingBringsItBackUp() {
    let a = makeActor()
    a.enterState(.done, quiet: true)
    a.startFollow(lookLeft: true)
    a.followShift(dx: 4, dy: 0)
    a.lift = 3
    a.fidgetIn = 10                            // a fidget is due
    a.holdUnderground(depth: 12)
    #expect(!a.following && a.followOffset.x == 0 && a.lift == 0)
    a.play("burrow")                           // the sink itself plays over the hold
    #expect(a.snapshot().bodyY == 0)
    stepUntilLoop(a)
    #expect(a.snapshot().bodyY == -12)
    #expect(a.snapshot().pose == "base")
    for _ in 0..<10 { a.step() }               // the poof fades
    #expect(a.particles.isEmpty)
    for _ in 0..<100 {                         // no fidget, and no twinkle sparkling in mid-air
        a.step()
        #expect(!a.isPlayingOnce)
        #expect(a.particles.isEmpty)
    }
    a.enterState(.waiting)                     // taken quietly: no alert jumping up
    #expect(!a.isPlayingOnce)
    #expect(a.badgeVisible)                    // its "!" is up once it comes back
    a.setMode("pet")
    a.setGaze(.left)
    a.startFollow(lookLeft: false)
    #expect(!a.following)
    #expect(a.snapshot().bodyY == -12)
    #expect(a.snapshot().badge == nil && a.snapshot().accessory == nil)
    #expect(a.ticksUntilChange() > 1000)       // and it wakes nobody
    a.reduceMotion = true                      // the still pose would stand on the ground
    #expect(a.snapshot().bodyY == -12)
}

@Test func releasedFromUnderGroundItsLoopResumes() {
    let a = makeActor()
    a.enterState(.idle, quiet: true)
    a.holdUnderground(depth: 12)
    a.enterState(.waiting)
    a.play("pop_up")                           // popping back up, over the hold
    #expect(a.snapshot().bodyY == -12)
    a.releaseUnderground()
    #expect(a.underground == nil)
    #expect(a.currentClipName == "pop_up")     // the pop-up carries on...
    stepUntilLoop(a)
    #expect(a.currentClipName == "ask")        // ...into the state's loop
    #expect(a.snapshot().bodyY == 0)
}

@Test func underReducedMotionAHeldCritterIsGoneAtOnce() {
    let a = makeActor(reduceMotion: true)
    a.enterState(.error, quiet: true)
    #expect(a.snapshot().bodyY == -1)          // error's still pose sinks a cell
    a.holdUnderground(depth: 12)
    #expect(a.snapshot().bodyY == -12)
    a.releaseUnderground()
    #expect(a.snapshot().bodyY == -1)
}
