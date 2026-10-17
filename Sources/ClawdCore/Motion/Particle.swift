import Foundation

/// One live particle, in cells relative to the actor (x across the base box, y down, ground =
/// row 10); velocities in cells per second.
public struct Particle: Equatable, Sendable {
    public var glyph: String
    public var color: String
    public var x: Double
    public var y: Double
    public var vx: Double
    public var vy: Double
    public var ay: Double
    public var sway: Double
    public var life: Int
    public var age: Int
    public var pop: Bool
    public var shrinkTo: String?

    public init(glyph: String, color: String, x: Double, y: Double, vx: Double = 0, vy: Double = 0,
                ay: Double = 0, sway: Double = 0, life: Int, age: Int = 0, pop: Bool = false,
                shrinkTo: String? = nil) {
        self.glyph = glyph
        self.color = color
        self.x = x
        self.y = y
        self.vx = vx
        self.vy = vy
        self.ay = ay
        self.sway = sway
        self.life = life
        self.age = age
        self.pop = pop
        self.shrinkTo = shrinkTo
    }

    public mutating func step(dt: Double) {
        vy += ay * dt
        x += vx * dt
        y += vy * dt
        age += 1
    }

    public var isAlive: Bool { age < life }

    /// Where and how to draw it, relative to the particle frame (the caller adds the body offset).
    public func draw() -> GlyphDraw {
        let swayShift = Double(jsRound(sin(Double(age) * 0.5) * sway))
        var gx = jsRound(x + swayShift)
        var gy = jsRound(y) + (pop && age < 2 ? -1 : 0)
        var g = glyph
        if let shrinkTo, Double(age) > Double(life) / 2 {
            g = shrinkTo
            gx += 1
            gy += 1
        }
        let alpha = Double(age) > 0.65 * Double(life) ? 0.5 : 1
        return GlyphDraw(glyph: g, color: color, x: gx, y: gy, alpha: alpha)
    }
}

public enum ParticleSpawner {
    /// The particles one trigger of `e` emits: all of `particles`, plus group
    /// `cycleIndex % cycle.count` of `cycle`.
    public static func spawn(_ e: EffectSpec, cycleIndex: Int, rng: MotionRNG) -> [Particle] {
        var group = e.particles ?? []
        if let cycle = e.cycle, !cycle.isEmpty { group += cycle[cycleIndex % cycle.count] }
        var out: [Particle] = []
        for spec in group {
            for i in 0..<Swift.max(1, spec.count ?? 1) {
                let color: String
                if let colors = spec.colors, !colors.isEmpty { color = colors[i % colors.count] }
                else { color = spec.color ?? "" }
                let x = rng.value(spec.x), y = rng.value(spec.y)
                let vx = spec.vx.map(rng.value) ?? 0, vy = spec.vy.map(rng.value) ?? 0
                out.append(Particle(glyph: spec.glyph, color: color, x: x, y: y, vx: vx, vy: vy,
                                    ay: spec.ay ?? 0, sway: spec.sway ?? 0, life: rng.integer(spec.life),
                                    pop: spec.pop ?? false, shrinkTo: spec.shrinkTo))
            }
        }
        return out
    }
}
