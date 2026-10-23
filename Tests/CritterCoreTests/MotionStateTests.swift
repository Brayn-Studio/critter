import Foundation
import Testing
@testable import CritterCore

private func makeActor(_ skin: SkinManifest = SkinLoader.builtin(), seed: UInt64 = 7, reduceMotion: Bool = false) -> MotionActor {
    MotionActor(skin: skin, rng: MotionRNG(seed: seed), reduceMotion: reduceMotion)
}

/// Steps until the one-shot ends (or `limit` ticks), returning how many steps it took.
@discardableResult
private func stepUntilLoop(_ a: MotionActor, limit: Int = 500) -> Int {
    var n = 0
    while a.isPlayingOnce && n < limit { a.step(); n += 1 }
    return n
}

// MARK: - enterState

@Test func quietEnterSetsLoopOnly() {
    let a = makeActor()
    a.enterState(.waiting, quiet: true)
    #expect(a.state == .waiting)
    #expect(a.currentClipName == "ask")
    #expect(!a.isPlayingOnce)
    #expect(a.badgeVisible)
    #expect(a.snapshot().badge?.x == 16)
    #expect(a.snapshot().accessory?.glyph == "q")
}

@Test func enterPlaysEnterThenLoop() {
    let a = makeActor()
    a.enterState(.done)
    #expect(a.currentClipName == "celebrate")
    #expect(a.isPlayingOnce)
    #expect(a.tint == nil)
    #expect(stepUntilLoop(a) == 25)
    #expect(a.currentClipName == "content")
}

@Test func leavingLaptopClosesBeforeAlert() {
    let a = makeActor()
    a.enterState(.running, quiet: true)
    #expect(a.variant == "laptop")
    #expect(a.currentClipName == "laptop")
    a.enterState(.waiting)
    #expect(a.currentClipName == "lap_close")
    #expect(a.snapshot().badge == nil)
    for _ in 0..<6 { a.step() }
    #expect(a.currentClipName == "lap_close")
    #expect(a.snapshot().badge == nil)
    a.step()                                   // lap_close is 7 ticks
    #expect(a.currentClipName == "alert")
    let popped = a.snapshot().badge
    #expect(popped != nil)
    a.step()
    a.step()                                   // badge settled, clock 9 is off the hop beat
    let resting = a.snapshot().badge
    #expect(resting != nil)
    #expect(popped!.y == resting!.y - 1)
    #expect(resting!.y == -7)
}

@Test func interruptedExitStillShowsBadge() {
    // the exit is cancelled (e.g. another Critter is dragged and this one starts following)
    let a = makeActor()
    a.enterState(.running, quiet: true)
    a.enterState(.waiting)
    for _ in 0..<3 { a.step() }
    #expect(a.currentClipName == "lap_close")
    a.cancelOnce()
    #expect(a.badgeVisible)
    #expect(a.currentClipName == "ask")        // the entrance is skipped, the loop goes on
    #expect(a.snapshot().badge?.y == -8)       // just appeared: hopping
    for _ in 0..<30 {
        a.step()
        #expect(a.currentClipName != "alert")
        #expect(a.snapshot().badge != nil)
    }

    // the exit is replaced by a layout hop: the badge shows once it lands
    let b = makeActor()
    b.enterState(.running, quiet: true)
    b.enterState(.waiting)
    b.step()
    b.travel(fromDx: 20, fromDy: 0, delay: 0)
    #expect(b.badgeVisible)
    stepUntilLoop(b)
    #expect(b.snapshot().badge != nil)

    // a newer state still drops the stale exit entirely
    let c = makeActor()
    c.enterState(.running, quiet: true)
    c.enterState(.waiting)
    c.enterState(.done, quiet: true)
    c.cancelOnce()
    #expect(c.snapshot().badge == nil)
}

@Test func staleEnterIsDropped() {
    let a = makeActor()
    a.enterState(.running, quiet: true)
    a.enterState(.waiting)                     // lap_close playing
    a.enterState(.done)                        // immediately done
    #expect(a.currentClipName == "celebrate")
    var seen: Set<String> = []
    for _ in 0..<30 {
        a.step()
        seen.insert(a.currentClipName ?? "")
    }
    #expect(!seen.contains("alert"))
    #expect(a.currentClipName == "content")
    for _ in 0..<300 {
        a.step()
        seen.insert(a.currentClipName ?? "")
    }
    #expect(!seen.contains("alert"))
}

@Test func doneToIdlePlaysSeen() {
    let a = makeActor()
    a.enterState(.done, quiet: true)
    a.enterState(.idle)
    #expect(a.currentClipName == "seen")
    #expect(a.tint == .dim)
    #expect(stepUntilLoop(a) == 8)
    #expect(a.currentClipName == "idle")
}

@Test func enterWithoutEnterClipCancelsOnce() {
    let a = makeActor()
    a.enterState(.waiting, quiet: true)
    var ok: Bool?
    a.play("blink") { ok = $0 }
    a.enterState(.idle)
    #expect(ok == false)
    #expect(!a.isPlayingOnce)
    #expect(a.currentClipName == "idle")
}

@Test func fallsAsleepAfter2000TicksAndWakes() {
    let a = makeActor()
    a.enterState(.idle, quiet: true)
    for _ in 0..<1999 { a.step() }
    #expect(!a.asleep)
    a.step()
    #expect(a.asleep)
    #expect(a.stateLoopName() == "sleep")
    #expect(a.currentClipName == "doze")
    #expect(a.snapshot().accessory == nil)
    #expect(stepUntilLoop(a) > 0)
    #expect(a.currentClipName == "sleep")
    for _ in 0..<300 {                         // no fidgets while asleep
        a.step()
        #expect(a.currentClipName == "sleep")
    }
    a.wake()
    #expect(!a.asleep)
    #expect(a.currentClipName == "wake")
    #expect(a.stateLoopName() == "idle")
    stepUntilLoop(a)
    #expect(a.currentClipName == "idle")
}

@Test func waitingTurnsImpatientAt500() {
    let a = makeActor()
    a.enterState(.waiting, quiet: true)
    for _ in 0..<480 { a.step() }
    for _ in 480..<499 {                       // the "!" hops 2 ticks in every 20
        a.step()
        #expect(a.snapshot().badge?.y == (a.clock % 20 < 2 ? -8 : -7))
    }
    #expect(a.stateLoopName() == "ask")
    a.step()
    #expect(a.stateLoopName() == "impatient")
    #expect(a.currentClipName == "impatient")
    for _ in 0..<24 {                          // now 2 in every 8
        a.step()
        #expect(a.snapshot().badge?.y == (a.clock % 8 < 2 ? -8 : -7))
    }
}

@Test func fidgetPlaysAPickAndReschedules() {
    let a = makeActor()
    a.enterState(.idle, quiet: true)
    let fidget = a.skin.state(.idle).fidget!
    let picks = Set(fidget.pick.map(\.clip))
    #expect((40...90).contains(a.fidgetIn))
    for _ in 0..<5 {
        let n = a.fidgetIn
        for _ in 0..<(n - 1) { a.step() }
        #expect(!a.isPlayingOnce)
        a.step()
        #expect(a.isPlayingOnce)
        #expect(picks.contains(a.currentClipName ?? ""))
        #expect((60...160).contains(a.fidgetIn))
        stepUntilLoop(a)
    }
}

@Test func noFidgetDuringMode() {
    let a = makeActor()
    a.enterState(.idle, quiet: true)
    a.setMode("pet")
    let fidgetIn = a.fidgetIn
    for _ in 0..<300 { a.step() }
    #expect(a.fidgetIn == fidgetIn)
    #expect(a.idleTicks == 0)
    #expect(!a.isPlayingOnce)
    #expect(a.currentClipName == "pet")
}

@Test func hiddenCritterHoldsItsFidgetButKeepsItsOtherTimers() {
    let a = makeActor()
    a.enterState(.idle, quiet: true)
    a.hidden = true
    let fidgetIn = a.fidgetIn
    for _ in 0..<300 { a.step() }
    #expect(!a.isPlayingOnce)                  // no invisible fidgets waking the clock
    #expect(a.fidgetIn == fidgetIn)
    #expect(a.idleTicks == 300)                // still on its way to sleep
    #expect(a.brainTicksLeft() == 2000 - 300)  // only the way to sleep counts, not the fidget
    a.hidden = false
    for _ in 0..<fidgetIn { a.step() }
    #expect(a.isPlayingOnce)                   // shown again: the countdown carries on
}

// MARK: - Work variants

@Test func activityDebounce() {
    let a = makeActor()
    a.enterState(.running, quiet: true)
    a.fidgetIn = 10_000
    a.setActivity("think")
    for _ in 0..<39 {
        a.step()
        #expect(a.variant == "laptop")
        #expect(a.currentClipName == "laptop")
    }
    a.step()
    #expect(a.variant == "think")
    #expect(a.currentClipName == "lap_close")
    stepUntilLoop(a)
    #expect(a.currentClipName == "think")
    #expect(a.stateLoopName() == "think")
}

@Test func switchToVariantWithEnterPlaysIt() {
    let a = makeActor()
    a.setActivity("read")
    a.enterState(.running, quiet: true)
    a.fidgetIn = 10_000
    a.setActivity("laptop")
    for _ in 0..<40 { a.step() }
    #expect(a.variant == "laptop")
    #expect(a.currentClipName == "lap_open")   // read has no exit; laptop's own enter
    stepUntilLoop(a)
    #expect(a.currentClipName == "laptop")
}

@Test func briefActivityFlickerIgnored() {
    let a = makeActor()
    a.enterState(.running, quiet: true)
    a.fidgetIn = 10_000
    a.setActivity("think")
    for _ in 0..<10 { a.step() }
    a.setActivity("laptop")
    for _ in 0..<300 {
        a.step()
        #expect(a.currentClipName != "lap_close")
    }
    #expect(a.variant == "laptop")
}

@Test func runningEntryUsesDesiredVariant() {
    let a = makeActor()
    a.setActivity("read")
    #expect(a.variant == "laptop")             // only remembered outside running
    a.enterState(.running)
    #expect(a.variant == "read")
    #expect(a.currentClipName == "work_enter")
    #expect(a.stateLoopName() == "read")
    stepUntilLoop(a)
    #expect(a.currentClipName == "read")
}

@Test func unknownActivityMeansDefaultVariant() {
    let a = makeActor()
    a.setActivity("juggle")
    a.setActivity("no_such_tool")
    a.enterState(.running, quiet: true)
    #expect(a.variant == "laptop")
    a.setActivity("bash")
    a.setActivity(nil)
    for _ in 0..<100 { a.step() }
    #expect(a.variant == "laptop")
}

// MARK: - Head markers and props

@Test func sunFollowsCosine() {
    let a = makeActor()
    a.enterState(.running, quiet: true)
    var frames: [Int: GlyphDraw] = [:]
    while a.clock <= 33 {
        frames[a.clock] = a.snapshot().accessory
        a.step()
    }
    #expect([0, 5, 10, 17, 25, 33].map { frames[$0]?.glyph } == ["sun0", "sun1", "sun3", "sun4", "sun2", "sun0"])
    #expect(frames[17]?.x == 6)
    #expect(frames[17]?.y == -9)
    #expect(frames[0]?.x == 9)                 // sun0 is 1×1: centred in the 7-row box
    #expect(frames[0]?.y == -6)
    #expect(frames[17]?.color == "#F2B33D")
}

@Test func accessoryHiddenWhenAsleepHeldOrMerged() {
    let a = makeActor()
    a.enterState(.waiting, quiet: true)
    #expect(a.snapshot().accessory != nil && a.snapshot().badge != nil)
    a.setMode("held")
    #expect(a.snapshot().accessory == nil && a.snapshot().badge == nil)
    a.setMode(nil)
    a.noAccessory = true
    #expect(a.snapshot().accessory == nil && a.snapshot().badge == nil)
    a.noAccessory = false
    a.hidden = true
    #expect(a.snapshot().accessory == nil && a.snapshot().badge == nil)
    a.hidden = false
    #expect(a.snapshot().accessory != nil && a.snapshot().badge != nil)

    var skin = SkinLoader.builtin()
    skin.states["idle"]!.accessory = "q"
    skin.states["idle"]!.sleep!.after = 5
    let b = makeActor(skin)
    b.enterState(.idle, quiet: true)
    #expect(b.snapshot().accessory != nil)
    for _ in 0..<5 { b.step() }
    #expect(b.asleep)
    #expect(b.snapshot().accessory == nil)
}

@Test func markersHiddenWhenKeyIsDeepOrHigh() {
    let a = makeActor()
    a.enterState(.error, quiet: true)
    func accessory(dy: Int) -> GlyphDraw? {
        a.play(clip: [ClipKey(pose: "base", ticks: 3, dx: 2, dy: dy)], name: nil)
        return a.snapshot().accessory
    }
    #expect(accessory(dy: -6) == nil)
    #expect(accessory(dy: 7) == nil)
    #expect(accessory(dy: -5) != nil)
    #expect(accessory(dy: 6) != nil)
    // the marker ignores the body's dx and dy, but moves with lag and lift
    a.lag = 2
    a.lift = 1
    #expect(accessory(dy: 3) == GlyphDraw(glyph: "bang", color: "#FF3B30", x: 8 + 2, y: -7 - 1, alpha: 1))
}

@Test func checkTwinklesEvery43Ticks() {
    let a = makeActor()
    a.enterState(.done, quiet: true)
    a.fidgetIn = 10_000
    #expect(a.snapshot().accessory?.glyph == "check")
    for _ in 0..<42 { a.step() }
    #expect(a.particles.isEmpty)
    a.step()
    #expect(a.clock == 43)
    #expect(a.particles.map(\.glyph) == ["spark"])
    #expect(a.snapshot().particles.first?.x == 14)
    #expect(a.snapshot().particles.first?.y == -9)
    a.noAccessory = true
    for _ in 0..<43 { a.step() }
    #expect(a.particles.isEmpty)
}

@Test func qBobsEvery7Ticks() {
    let a = makeActor()
    a.enterState(.waiting, quiet: true)
    for _ in 0..<28 {
        #expect(a.snapshot().accessory?.y == ((a.clock / 7) % 2 == 1 ? -9 : -8))
        #expect(a.snapshot().accessory?.x == 7)
        a.step()
    }
}

@Test func juggleBallsFollowFormula() {
    let a = makeActor()
    a.setActivity("juggle")
    a.enterState(.running, quiet: true)
    #expect(a.snapshot().props == [
        GlyphDraw(glyph: "seed", color: "#6BCB5F", x: 3, y: -2, alpha: 1),
        GlyphDraw(glyph: "seed", color: "#FF8FB8", x: 7, y: -8, alpha: 1),
        GlyphDraw(glyph: "seed", color: "#FFD24A", x: 10, y: -8, alpha: 1),
    ])
    a.lag = 1
    a.lift = 2
    #expect(a.snapshot().props[0].x == 4)
    #expect(a.snapshot().props[0].y == -4)
    a.play("blink")                            // only while the variant's loop plays
    #expect(a.snapshot().props.isEmpty)
}

// MARK: - Reduced motion

@Test func reduceMotionShowsStills() {
    let skin = SkinLoader.builtin()
    let a = makeActor(reduceMotion: true)
    for s in PetState.allCases {
        a.enterState(s, quiet: true)
        #expect(a.snapshot().pose == skin.state(s).still)
    }
    a.enterState(.error, quiet: true)
    #expect(a.snapshot().pose == "slump")
    #expect(a.snapshot().bodyY == -1)
    a.lift = 2
    #expect(a.snapshot().bodyY == 1)
    a.lift = 0

    a.enterState(.running, quiet: true)
    #expect(a.snapshot().accessory?.glyph == "sun3")
    #expect(a.snapshot().pose == "lap_a")
    #expect(a.snapshot().bodyX == 0)
    a.setMode("held")
    #expect(a.snapshot().pose == "held_a")
    a.setMode(nil)

    a.enterState(.waiting)                     // badge at once, and it never hops
    #expect(a.badgeVisible)
    for _ in 0..<25 {
        #expect(a.snapshot().badge?.y == -7)
        #expect(a.snapshot().accessory?.y == -8)
        a.step()
    }

    a.enterState(.done)
    #expect(!a.isPlayingOnce)                  // no entrance under reduced motion
    for _ in 0..<60 {
        a.step()
        #expect(a.particles.isEmpty)
    }

    a.enterState(.idle)
    for _ in 0..<2000 { a.step() }
    #expect(a.asleep)
    #expect(a.snapshot().pose == "sleep")
}

@Test func reduceMotionSwitchesVariantWithoutExit() {
    let a = makeActor(reduceMotion: true)
    a.enterState(.running, quiet: true)
    a.setActivity("think")
    for _ in 0..<40 { a.step() }
    #expect(a.variant == "think")
    #expect(!a.isPlayingOnce)
    #expect(a.currentClipName == "think")
}

// MARK: - ticksUntilChange

@Test func ticksUntilChangeCountsBrainAndAccessories() {
    let long = [ClipKey(pose: "base", ticks: 1000)]

    // fidget countdown
    let idle = makeActor()
    idle.enterState(.idle, quiet: true)
    idle.fidgetIn = 5
    #expect(idle.ticksUntilChange() == 5)
    // falling asleep
    idle.fidgetIn = 10_000
    idle.idleTicks = 1995
    #expect(idle.ticksUntilChange() == 5)

    // spinner frame (think's first key is 10 ticks; s0 → s1 at clock 4)
    let spin = makeActor()
    spin.setActivity("think")
    spin.enterState(.running, quiet: true)
    spin.fidgetIn = 10_000
    #expect(spin.ticksUntilChange() == 4)

    // waiting: badge hop ends at clock 2, then the q bob at 7, then impatience
    let wait = makeActor()
    wait.enterState(.waiting, quiet: true)
    wait.setLoop(clip: long, name: nil)
    #expect(wait.ticksUntilChange() == 2)
    wait.step()
    wait.step()
    #expect(wait.ticksUntilChange() == 5)
    wait.noAccessory = true
    wait.waitTicks = 497
    #expect(wait.ticksUntilChange() == 3)

    // check twinkle
    let done = makeActor()
    done.enterState(.done, quiet: true)
    done.setLoop(clip: long, name: nil)
    done.fidgetIn = 10_000
    #expect(done.ticksUntilChange() == 43)

    // juggled balls move every tick
    let juggle = makeActor()
    juggle.setActivity("juggle")
    juggle.enterState(.running, quiet: true)
    #expect(juggle.ticksUntilChange() == 1)

    // variant debounce
    let run = makeActor()
    run.enterState(.running, quiet: true)
    run.noAccessory = true
    run.fidgetIn = 10_000
    run.setLoop(clip: long, name: nil)
    run.setActivity("think")
    #expect(run.ticksUntilChange() == 40)
    for _ in 0..<25 { run.step() }
    #expect(run.ticksUntilChange() == 15)

    // nothing counts down while the brain is off
    let off = makeActor()
    off.enterState(.idle, quiet: true)
    off.brainEnabled = false
    off.setLoop(clip: long, name: nil)
    #expect(off.ticksUntilChange() == 1000)
}
