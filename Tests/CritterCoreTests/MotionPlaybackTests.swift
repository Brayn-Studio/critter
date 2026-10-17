import Foundation
import Testing
@testable import CritterCore

private func makeActor(reduceMotion: Bool = false) -> MotionActor {
    MotionActor(skin: SkinLoader.builtin(), rng: MotionRNG(seed: 7), reduceMotion: reduceMotion)
}

@Test func onceResumesLoopAndCompletesTrue() {
    let a = makeActor()
    a.setLoop("idle")
    var ok: Bool?
    a.play("blink") { ok = $0 }
    #expect(a.currentClipName == "blink")
    #expect(a.isPlayingOnce)
    a.step()
    #expect(ok == nil)
    a.step()
    #expect(ok == true)
    #expect(!a.isPlayingOnce)
    #expect(a.currentClipName == "idle")
    #expect(a.currentKeyIndex == 0)
}

@Test func replacingOnceCompletesFalse() {
    let a = makeActor()
    a.setLoop("idle")
    var first: Bool?, second: Bool?
    a.play("blink") { first = $0 }
    a.play("wink") { second = $0 }
    #expect(first == false)
    #expect(second == nil)
    #expect(a.currentClipName == "wink")
    a.cancelOnce()
    #expect(second == false)
    #expect(a.currentClipName == "idle")
    #expect(!a.isPlayingOnce)
}

@Test func modeTakesOverBaseUntilCleared() {
    let a = makeActor()
    a.setLoop("idle")
    a.setMode("held")
    #expect(a.modeName == "held")
    #expect(a.currentClipName == "held")
    a.setLoop("ask")                      // base changes underneath the mode
    #expect(a.currentClipName == "held")
    a.setMode(nil)
    #expect(a.modeName == nil)
    #expect(a.currentClipName == "ask")
}

@Test func onceOverModeResumesMode() {
    let a = makeActor()
    a.setLoop("idle")
    a.setMode("pet")
    var ok: Bool?
    a.play("notice") { ok = $0 }          // 2 ticks
    #expect(a.currentClipName == "notice")
    a.step()
    a.step()
    #expect(ok == true)
    #expect(a.currentClipName == "pet")
}

@Test func effectFiresAtKeyStart() {
    let a = makeActor()
    a.setLoop("idle")
    a.play("jump")                         // key 0 fires "dust" (2 particles)
    #expect(a.particles.count == 2)
    a.step()                               // key 1 fires "tilde" (2 more)
    #expect(a.particles.count == 4)
}

@Test func reduceMotionEmitsNoParticles() {
    let a = makeActor(reduceMotion: true)
    a.setLoop("idle")
    a.play("jump")
    #expect(a.particles.isEmpty)
    a.emit("dust")
    #expect(a.particles.isEmpty)
}

@Test func unknownAndInternalEffectsAreIgnored() {
    let a = makeActor()
    a.emit("no_such_effect")
    a.emit("@seat")
    #expect(a.particles.isEmpty)
}

@Test func completionMayStartAnotherClip() {
    let a = makeActor()
    a.setLoop("idle")
    a.play("blink") { [unowned a] _ in a.play("wink") }
    a.step()
    a.step()
    #expect(a.currentClipName == "wink")
    #expect(a.isPlayingOnce)
}

@Test func bodyYFollowsKeyAndLift() {
    let a = makeActor()
    a.play(clip: [ClipKey(pose: "base", ticks: 3, dx: 1, dy: -2, effect: nil)], name: nil)
    #expect(a.currentClipName == nil)
    var s = a.snapshot()
    #expect(s.pose == "base")
    #expect(s.bodyX == 1)
    #expect(s.bodyY == -2)
    a.lift = 3
    a.lag = 2
    s = a.snapshot()
    #expect(s.bodyY == 1)
    #expect(s.bodyX == 3)
}

@Test func shadowWidthByHeight() {
    let a = makeActor()
    func width(dy: Int) -> Int {
        a.play(clip: [ClipKey(pose: "base", ticks: 3, dx: 0, dy: dy)], name: nil)
        return a.snapshot().shadowWidth
    }
    #expect(width(dy: 2) == 10)
    #expect(width(dy: 4) == 6)
    #expect(width(dy: 5) == 6)
    #expect(width(dy: 6) == 2)
    #expect(width(dy: 0) == 0)
    #expect(width(dy: -2) == 0)
    a.lift = 3
    #expect(width(dy: 0) == 6)
}

@Test func particlesFollowBodyOffsets() {
    let a = makeActor()
    a.play(clip: [ClipKey(pose: "base", ticks: 5, dx: 2, dy: 0, effect: "dust")], name: nil)
    a.lag = 1
    a.lift = 2
    let s = a.snapshot()
    #expect(s.particles.count == 2)
    #expect(s.particles[0].x == 2 + 2 + 1)
    #expect(s.particles[0].y == 9 - 2)
    #expect(s.particles[0].color == "#B4BAC4")
}

@Test func snapshotCarriesLookAndHiddenDrawsNothing() {
    let a = makeActor()
    a.setLoop("idle")
    a.tint = .dim
    a.alpha = 0.55
    a.z = 0
    a.emit("dust")
    #expect(a.snapshot().particles.count == 2)
    a.hidden = true
    let s = a.snapshot()
    #expect(s.hidden)
    #expect(s.tint == .dim)
    #expect(s.alpha == 0.55)
    #expect(s.z == 0)
    #expect(s.offsetX == 0 && s.offsetY == 0)
    #expect(s.particles.isEmpty)
    #expect(s.props.isEmpty)
    #expect(s.accessory == nil && s.badge == nil)
}

@Test func ticksUntilChangeIsRemainingKeyTicks() {
    let a = makeActor()
    a.setLoop("idle")
    #expect(a.ticksUntilChange() == 40)
    for _ in 0..<10 { a.step() }
    #expect(a.ticksUntilChange() == 30)
    a.emit("dust")
    #expect(a.ticksUntilChange() == 1)
}

@Test func clockCountsSteps() {
    let a = makeActor()
    #expect(a.clock == 0)
    for _ in 0..<5 { a.step() }
    #expect(a.clock == 5)
}
