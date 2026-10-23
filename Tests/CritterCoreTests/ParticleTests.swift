import Foundation
import Testing
@testable import CritterCore
@testable import CritterKit

@Test func dustParticleMovesAndDies() {
    var p = ParticleSpawner.spawn(SkinLoader.builtin().effects["dust"]!, cycleIndex: 0, rng: MotionRNG(seed: 1))[0]
    p.step(dt: 0.06)
    #expect(p.draw().x == 0)          // 1 - 12*0.06 = 0.28
    #expect(p.isAlive)
    for _ in 0..<3 { p.step(dt: 0.06) }
    #expect(!p.isAlive)               // life 4
}

@Test func confettiHasSixteenCyclingColors() throws {
    let json = ##"{"particles": [{"count": 16, "glyph": "dot", "colors": ["#B39DF3", "#34C759", "#FFD60A", "#64D2FF", "#FF7096", "#F2F2F7"], "x": [5, 12], "y": -1, "vx": [-18, 18], "vy": [-34, -16], "ay": 80, "life": [13, 19]}]}"##
    let effect = try JSONDecoder().decode(EffectSpec.self, from: Data(json.utf8))
    let colors = effect.particles![0].colors!
    let ps = ParticleSpawner.spawn(effect, cycleIndex: 0, rng: MotionRNG(seed: 3))
    #expect(ps.count == 16)
    #expect(colors.count == 6)
    for (i, p) in ps.enumerated() {
        #expect(p.color == colors[i % 6])
        #expect(p.x >= 5 && p.x <= 12)
        #expect(p.y == -1)
        #expect(p.vx >= -18 && p.vx <= 18)
        #expect(p.vy >= -34 && p.vy <= -16)
        #expect(p.ay == 80)
        #expect((13...19).contains(p.life))
    }
    #expect(Set(ps.map(\.x)).count > 1)
}

@Test func cycleEffectsTakeTheGroupForTheirTurn() {
    let zzz = SkinLoader.builtin().effects["zzz"]!
    let rng = MotionRNG(seed: 1)
    #expect(ParticleSpawner.spawn(zzz, cycleIndex: 0, rng: rng).map(\.glyph) == ["z"])
    #expect(ParticleSpawner.spawn(zzz, cycleIndex: 1, rng: rng).map(\.glyph) == ["Z"])
    #expect(ParticleSpawner.spawn(zzz, cycleIndex: 2, rng: rng).map(\.glyph) == ["z"])
}

@Test func drawRules() {
    // pop: lifted one cell for the first two ticks only
    var pop = Particle(glyph: "bang", color: "#FF3B30", x: 16, y: -7, life: 10, pop: true)
    #expect(pop.draw().y == -8)
    pop.step(dt: 0.06)
    #expect(pop.draw().y == -8)
    pop.step(dt: 0.06)
    #expect(pop.draw().y == -7)

    // sway: x + round(sin(age * 0.5) * sway)
    var sway = Particle(glyph: "z", color: "#A3A9B4", x: 15, y: -2, sway: 1, life: 30)
    #expect(sway.draw().x == 15)    // sin 0 = 0
    sway.age = 3
    #expect(sway.draw().x == 16)    // sin 1.5 ≈ 1.0
    sway.age = 7
    #expect(sway.draw().x == 15)    // sin 3.5 ≈ -0.35
    sway.age = 9
    #expect(sway.draw().x == 14)    // sin 4.5 ≈ -0.98

    // fades to half alpha once past 65 % of its life
    var fade = Particle(glyph: "dot", color: "#B4BAC4", x: 0, y: 0, life: 10)
    fade.age = 6
    #expect(fade.draw().alpha == 1)
    fade.age = 7
    #expect(fade.draw().alpha == 0.5)

    // twinkle shrinks to "dot" past half its life, shifted one cell right and down
    var twinkle = ParticleSpawner.spawn(SkinLoader.builtin().effects["twinkle"]!, cycleIndex: 0, rng: MotionRNG(seed: 1))[0]
    twinkle.age = 3
    #expect(twinkle.draw() == GlyphDraw(glyph: "spark", color: "#E9EDF2", x: 14, y: -9, alpha: 1))
    twinkle.age = 4
    #expect(twinkle.draw() == GlyphDraw(glyph: "dot", color: "#E9EDF2", x: 15, y: -8, alpha: 0.5))
}

@Test func jsRoundMatchesMathRound() {
    #expect(jsRound(-2.5) == -2)
    #expect(jsRound(27.5) == 28)
    #expect(jsRound(-17.5) == -17)
    #expect(jsRound(1.28) == 1)
    #expect(jsRound(-0.4) == 0)
}

@Test func rngIsDeterministicPerSeed() {
    let a = MotionRNG(seed: 42), b = MotionRNG(seed: 42), c = MotionRNG(seed: 43)
    let sa = (0..<10).map { _ in a.unit() }
    let sb = (0..<10).map { _ in b.unit() }
    let sc = (0..<10).map { _ in c.unit() }
    #expect(sa == sb)
    #expect(sa != sc)
    #expect(sa.allSatisfy { $0 >= 0 && $0 < 1 })
}

@Test func rngIntegersAreInclusive() {
    let rng = MotionRNG(seed: 5)
    let drawn = Set((0..<500).map { _ in rng.integer(in: 0...2) })
    #expect(drawn == [0, 1, 2])
    let lives = Set((0..<500).map { _ in rng.integer(Span(13, 19)) })
    #expect(lives == Set(13...19))
    #expect(rng.value(Span(4)) == 4)
}

@Test func particleKnowsWhenItsDrawingChanges() {
    // A still particle changes only when it fades (age 7 of 10) -- or, past that, when it dies.
    let still = Particle(glyph: "dot", color: "#B4BAC4", x: 0, y: 0, life: 10)
    #expect(still.ticksUntilDrawChanges(dt: 0.06) == 7)
    var faded = still
    faded.age = 7
    #expect(faded.ticksUntilDrawChanges(dt: 0.06) == 3)

    // A floating z: each predicted tick is the first one drawn differently, and stepping that
    // far always lands on a different drawing (or the end of its life).
    var z = Particle(glyph: "z", color: "#A3A9B4", x: 15, y: -2, vx: 3, vy: -5, sway: 1, life: 30)
    var waits: [Int] = []
    while z.isAlive {
        let wait = z.ticksUntilDrawChanges(dt: 0.06)
        waits.append(wait)
        let before = z.draw()
        for step in 1...wait {
            z.step(dt: 0.06)
            if step < wait { #expect(z.draw() == before) }
        }
        #expect(!z.isAlive || z.draw() != before)
    }
    #expect(waits.reduce(0, +) == 30)
    #expect(waits.contains { $0 > 1 })          // it doesn't need the clock every tick
}

@Test func actorSleepsBetweenParticleMoves() {
    let a = MotionActor(skin: SkinLoader.builtin(), rng: MotionRNG(seed: 7))
    a.setLoop(clip: [ClipKey(pose: "base", ticks: 1000)], name: nil)
    a.brainEnabled = false
    a.particles = [Particle(glyph: "dot", color: "#B4BAC4", x: 0, y: 0, life: 10)]
    #expect(a.ticksUntilChange() == 7)          // its fade, not every tick
    for _ in 0..<7 { a.step() }
    #expect(a.snapshot().particles.first?.alpha == 0.5)
    #expect(a.ticksUntilChange() == 3)          // then its end
}
