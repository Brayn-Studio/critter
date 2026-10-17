import Foundation

/// A complete, data-driven description of how the pet looks and animates: no animation is
/// hardcoded in Swift, so a brand-replacement skin only has to supply a valid manifest.
/// Field names equal the JSON keys of schema 2 (see the animation v2 design, section 3).
public struct SkinManifest: Codable, Sendable, Equatable {
    public var schema: Int
    public var name: String
    /// What the settings call the skin ("小芽 Sprig"); optional, see `SkinChoice.title`.
    public var title: String?
    /// Duration of one tick in milliseconds.
    public var tickMs: Int
    /// Base box `[width, height]` in square pixel cells; row `height` is the ground.
    public var grid: [Int]
    public var palette: [String: String]
    public var parts: [String: SkinPart]
    public var poses: [String: [String]]
    public var glyphs: [String: [String]]
    public var clips: [String: MotionClip]
    public var effects: [String: EffectSpec]
    public var accessories: [String: AccessorySpec]
    public var states: [String: StateSpec]
    public var interactions: InteractionNames
    public var props: [String: PropSpec]

    /// The spec of `s`. Only call on a manifest that passed `SkinValidator`, which
    /// guarantees all five states exist.
    public func state(_ s: PetState) -> StateSpec { states[s.rawValue]! }
}

/// A rectangle of pixel rows placed at `at` (top-left, base-box coordinates, may be negative).
public struct SkinPart: Codable, Sendable, Equatable {
    public var at: [Int]
    public var rows: [String]
}

/// One key of a motion clip: show `pose` for `ticks` ticks offset by (`dx`, `dy`) cells,
/// firing `effect` once when the key starts. JSON is an array: `[pose, ticks]`,
/// `[pose, ticks, dx, dy]` or `[pose, ticks, dx, dy, effect]`.
public struct ClipKey: Codable, Sendable, Equatable {
    public var pose: String
    public var ticks: Int
    public var dx: Int
    public var dy: Int
    public var effect: String?

    public init(pose: String, ticks: Int, dx: Int = 0, dy: Int = 0, effect: String? = nil) {
        self.pose = pose
        self.ticks = ticks
        self.dx = dx
        self.dy = dy
        self.effect = effect
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        guard let n = c.count, n == 2 || n == 4 || n == 5 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "clip key needs 2, 4 or 5 elements"))
        }
        pose = try c.decode(String.self)
        ticks = try c.decode(Int.self)
        dx = n >= 4 ? try c.decode(Int.self) : 0
        dy = n >= 4 ? try c.decode(Int.self) : 0
        effect = n == 5 ? try c.decode(String.self) : nil
    }

    /// Emits the shortest form that can express the key.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(pose)
        try c.encode(ticks)
        if let effect {
            try c.encode(dx)
            try c.encode(dy)
            try c.encode(effect)
        } else if dx != 0 || dy != 0 {
            try c.encode(dx)
            try c.encode(dy)
        }
    }
}

public typealias MotionClip = [ClipKey]

/// A number or an inclusive `[min, max]` range (uniformly random when min < max).
public struct Span: Codable, Sendable, Equatable {
    public var min: Double
    public var max: Double

    public init(_ v: Double) { min = v; max = v }
    public init(_ a: Double, _ b: Double) { min = a; max = b }

    public init(from decoder: Decoder) throws {
        if let v = try? decoder.singleValueContainer().decode(Double.self) {
            self.init(v)
            return
        }
        var c = try decoder.unkeyedContainer()
        let a = try c.decode(Double.self)
        let b = try c.decode(Double.self)
        self.init(a, b)
    }

    public func encode(to encoder: Encoder) throws {
        if min == max {
            var c = encoder.singleValueContainer()
            try c.encode(min)
        } else {
            var c = encoder.unkeyedContainer()
            try c.encode(min)
            try c.encode(max)
        }
    }
}

/// One emitted particle (or a repeated group, via `count`).
public struct ParticleSpec: Codable, Sendable, Equatable {
    public var count: Int?
    public var glyph: String
    public var color: String?
    public var colors: [String]?
    public var x: Span
    public var y: Span
    public var vx: Span?
    public var vy: Span?
    public var ay: Double?
    public var life: Span
    public var sway: Double?
    public var pop: Bool?
    public var shrinkTo: String?
}

/// A particle effect: all `particles` on every trigger, or the next group of `cycle` each time.
public struct EffectSpec: Codable, Sendable, Equatable {
    public var particles: [ParticleSpec]?
    public var cycle: [[ParticleSpec]]?
}

/// A marker above the head (spinner, question mark, check, bang).
public struct AccessorySpec: Codable, Sendable, Equatable {
    public var glyph: String?
    public var frames: [String]?
    public var color: String
    public var periodMs: Int?
    public var box: Int?
    public var reduced: String?
    public var bobEvery: Int?
    public var twinkleEvery: Int?
    public var twinkle: String?
}

/// A clip name with a pick weight; JSON is `["blink", 6]`.
public struct WeightedClip: Codable, Sendable, Equatable {
    public var clip: String
    public var weight: Int

    public init(clip: String, weight: Int) {
        self.clip = clip
        self.weight = weight
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        clip = try c.decode(String.self)
        weight = try c.decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(clip)
        try c.encode(weight)
    }
}

/// Random small gestures: every `every[0]...every[1]` ticks, one weighted pick plays.
public struct FidgetSpec: Codable, Sendable, Equatable {
    public var every: [Int]
    public var pick: [WeightedClip]
}

public struct SleepSpec: Codable, Sendable, Equatable {
    public var after: Int
    public var doze: String
    public var loop: String
    public var wake: String
    public var still: String
}

public struct ImpatientSpec: Codable, Sendable, Equatable {
    public var after: Int
    public var loop: String
}

public struct BadgeSpec: Codable, Sendable, Equatable {
    public var glyph: String
    public var color: String
    public var x: Int
    public var hopEvery: Int
    public var impatientHopEvery: Int
}

public struct VariantSpec: Codable, Sendable, Equatable {
    public var loop: String
    public var enter: String?
    public var exit: String?
    public var prop: String?
}

/// The poses a state looks around with, in place of `interactions.look*` (so a state can keep
/// what it wears, like the done state's flower, while its eyes follow the pointer).
public struct GazePoses: Codable, Sendable, Equatable {
    public var left: String
    public var right: String
    public var up: String
    public var down: String
    public var center: String

    public func pose(_ zone: GazeZone) -> String {
        switch zone {
        case .left: left
        case .right: right
        case .up: up
        case .down: down
        case .center: center
        }
    }
}

/// A color post-processing effect applied to a whole state's poses.
public enum Tint: String, Codable, Sendable {
    case dim
}

/// Everything one `PetState` needs: entry and loop clips, tint, head marker, the pose shown
/// under reduced motion (`still`), and the optional behaviours layered on top.
public struct StateSpec: Codable, Sendable, Equatable {
    public var enter: String?
    public var loop: String?
    public var tint: Tint?
    public var accessory: String?
    public var still: String
    public var stillDy: Int?
    public var seen: String?
    public var fidget: FidgetSpec?
    public var sleep: SleepSpec?
    public var impatient: ImpatientSpec?
    public var badge: BadgeSpec?
    public var variants: [String: VariantSpec]?
    public var defaultVariant: String?
    public var gaze: GazePoses?
}

/// Names of the clips, poses and effects the engine uses for interactions and orchestration.
public struct InteractionNames: Codable, Sendable, Equatable {
    public var notice: String
    public var pet: String
    public var petEnd: String
    public var press: String
    public var boopEnd: String
    public var held: String
    public var heldStill: String
    public var drop: String
    public var blink: String
    public var join: String
    public var leave: String
    public var appear: String
    public var vanish: String
    public var hop: String
    public var land: String
    public var blinkPose: String
    public var landDust: String
    public var walkLeft: [String]
    public var walkRight: [String]
    public var lookLeft: String
    public var lookRight: String
    public var lookUp: String
    public var lookDown: String
    public var lookCenter: String
}

/// A prop bound to a clip variant (the juggled balls).
public struct PropSpec: Codable, Sendable, Equatable {
    public var glyph: String
    public var colors: [String]
}

/// Checks a manifest is internally consistent and complete enough to render, so a broken or
/// partial custom skin can be safely rejected (falling back to the builtin) instead of
/// crashing or rendering garbage. Effect names starting with "@" are reserved for effects
/// the engine generates at runtime, so a manifest may neither define nor reference them.
///
/// Every number is bounded too, so no skin can trap (an Int conversion or overflow) or hog
/// the CPU at runtime: `tickMs` 16…1000, offsets within ±64 cells, pixel art at most 64×64,
/// durations and periods 1…100000 (ticks, or ms for a spinner), badge hops 1…1000 ticks,
/// fidget weights 1…1000, at most 64 particles per spec living 1…300 ticks, and particle
/// positions, speeds, acceleration and sway within ±1000.
public enum SkinValidator {
    public static func problems(_ m: SkinManifest) -> [String] {
        var out: [String] = []
        func bad(_ s: String) { out.append(s) }
        func number<T: Comparable>(_ v: T, _ range: ClosedRange<T>, _ what: String) {
            if !range.contains(v) { bad("\(what) must be within \(range.lowerBound)…\(range.upperBound)") }
        }
        func span(_ s: Span?, _ range: ClosedRange<Double>, _ what: String) {
            guard let s else { return }
            if !range.contains(s.min) || !range.contains(s.max) {
                bad("\(what) must be within \(range.lowerBound)…\(range.upperBound)")
            }
        }
        let cells = -64...64, ticks = 1...100_000, motion = -1000.0...1000.0

        if m.schema != 2 { bad("unsupported schema \(m.schema) (need 2)") }
        if let t = m.title, t.isEmpty || t.count > 40 { bad("title must be 1…40 characters") }
        number(m.tickMs, 16...1000, "tickMs")
        // The renderer, layout, hover and gaze all draw an 18×10 box with the ground on row 10.
        if m.grid != [18, 10] { bad("grid must be [18, 10]") }

        let paletteChars = Set(m.palette.keys.compactMap { $0.count == 1 ? $0.first : nil })
        if paletteChars.contains(".") { bad("palette must not define '.' (transparent)") }
        for (key, value) in m.palette where !isHex(value) { bad("palette \(key) is not a #RRGGBB color") }

        func checkRows(_ rows: [String], _ what: String, allowed: (Character) -> Bool) {
            if rows.isEmpty { bad("\(what) has no rows"); return }
            let width = rows[0].count
            if width == 0 || rows.contains(where: { $0.count != width }) { bad("\(what) has ragged rows") }
            if rows.count > 64 || width > 64 { bad("\(what) is larger than 64×64") }
            for ch in Set(rows.joined()) where ch != "." && !allowed(ch) {
                bad("\(what) uses character '\(ch)' not allowed")
            }
        }

        for (name, part) in m.parts {
            if part.at.count != 2 { bad("part \(name) needs at: [x, y]") }
            for v in part.at { number(v, cells, "part \(name) at") }
            checkRows(part.rows, "part \(name)") { paletteChars.contains($0) }
        }
        for (name, glyph) in m.glyphs { checkRows(glyph, "glyph \(name)") { $0 == "#" } }

        for (name, partNames) in m.poses {
            if partNames.isEmpty { bad("pose \(name) has no parts") }
            for p in partNames where m.parts[p] == nil { bad("pose \(name) references unknown part \(p)") }
        }

        func pose(_ n: String, _ ctx: String) { if m.poses[n] == nil { bad("\(ctx) references unknown pose \(n)") } }
        func clip(_ n: String, _ ctx: String) { if m.clips[n] == nil { bad("\(ctx) references unknown clip \(n)") } }
        func effect(_ n: String, _ ctx: String) { if m.effects[n] == nil { bad("\(ctx) references unknown effect \(n)") } }
        func glyph(_ n: String, _ ctx: String) { if m.glyphs[n] == nil { bad("\(ctx) references unknown glyph \(n)") } }
        func color(_ c: String, _ ctx: String) { if !isHex(c) { bad("\(ctx) has invalid color \(c)") } }

        for (name, keys) in m.clips {
            if keys.isEmpty { bad("clip \(name) has no keys") }
            for key in keys {
                pose(key.pose, "clip \(name)")
                number(key.ticks, ticks, "clip \(name) key ticks")
                number(key.dx, cells, "clip \(name) key dx")
                number(key.dy, cells, "clip \(name) key dy")
                if let e = key.effect { effect(e, "clip \(name)") }
            }
        }

        for (name, spec) in m.effects {
            if name.hasPrefix("@") { bad("effect \(name) uses the reserved '@' prefix") }
            if spec.particles == nil && spec.cycle == nil { bad("effect \(name) has neither particles nor cycle") }
            let groups = (spec.particles.map { [$0] } ?? []) + (spec.cycle ?? [])
            if groups.contains(where: \.isEmpty) { bad("effect \(name) has an empty particle group") }
            for p in groups.joined() {
                glyph(p.glyph, "effect \(name)")
                if let s = p.shrinkTo { glyph(s, "effect \(name)") }
                if let c = p.color { color(c, "effect \(name)") }
                for c in p.colors ?? [] { color(c, "effect \(name)") }
                if p.color == nil && (p.colors ?? []).isEmpty { bad("effect \(name) has a particle without a color") }
                if let n = p.count { number(n, 1...64, "effect \(name) particle count") }
                span(p.life, 1...300, "effect \(name) particle life")
                span(p.x, motion, "effect \(name) particle x")
                span(p.y, motion, "effect \(name) particle y")
                span(p.vx, motion, "effect \(name) particle vx")
                span(p.vy, motion, "effect \(name) particle vy")
                if let v = p.ay { number(v, motion, "effect \(name) particle ay") }
                if let v = p.sway { number(v, motion, "effect \(name) particle sway") }
            }
        }

        for (name, a) in m.accessories {
            color(a.color, "accessory \(name)")
            if a.glyph == nil && (a.frames ?? []).isEmpty { bad("accessory \(name) has no glyph or frames") }
            if let g = a.glyph { glyph(g, "accessory \(name)") }
            for g in a.frames ?? [] { glyph(g, "accessory \(name)") }
            if let g = a.reduced { glyph(g, "accessory \(name)") }
            if let e = a.twinkle { effect(e, "accessory \(name)") }
            if let v = a.periodMs { number(v, 1...100_000, "accessory \(name) periodMs") }
            if let v = a.box { number(v, 1...64, "accessory \(name) box") }
            if let v = a.bobEvery { number(v, ticks, "accessory \(name) bobEvery") }
            if let v = a.twinkleEvery { number(v, ticks, "accessory \(name) twinkleEvery") }
        }

        for state in PetState.allCases where m.states[state.rawValue] == nil {
            bad("missing state \(state.rawValue)")
        }
        for (name, s) in m.states {
            let ctx = "state \(name)"
            if PetState(rawValue: name) == nil { bad("\(ctx) is not a known state") }
            if let c = s.enter { clip(c, ctx) }
            if let c = s.loop { clip(c, ctx) }
            if let c = s.seen { clip(c, ctx) }
            if s.loop == nil && (s.variants ?? [:]).isEmpty { bad("\(ctx) has neither loop nor variants") }
            pose(s.still, ctx)
            if let a = s.accessory, m.accessories[a] == nil { bad("\(ctx) references unknown accessory \(a)") }
            if let d = s.stillDy { number(d, cells, "\(ctx) stillDy") }
            if let f = s.fidget {
                if f.every.count != 2 || !f.every.allSatisfy(ticks.contains) || f.every[1] < f.every[0] {
                    bad("\(ctx) fidget.every must be [min, max] within \(ticks.lowerBound)…\(ticks.upperBound)")
                }
                if f.pick.isEmpty { bad("\(ctx) fidget has nothing to pick") }
                for w in f.pick {
                    clip(w.clip, ctx)
                    number(w.weight, 1...1000, "\(ctx) fidget weight")
                }
            }
            if let z = s.sleep {
                clip(z.doze, ctx); clip(z.loop, ctx); clip(z.wake, ctx); pose(z.still, ctx)
                number(z.after, ticks, "\(ctx) sleep.after")
            }
            if let i = s.impatient {
                clip(i.loop, ctx)
                number(i.after, ticks, "\(ctx) impatient.after")
            }
            if let g = s.gaze {
                for p in [g.left, g.right, g.up, g.down, g.center] { pose(p, "\(ctx) gaze") }
            }
            if let b = s.badge {
                glyph(b.glyph, ctx); color(b.color, ctx)
                number(b.x, cells, "\(ctx) badge x")
                // Scanned tick by tick for the next hop, so kept short.
                number(b.hopEvery, 1...1000, "\(ctx) badge hopEvery")
                number(b.impatientHopEvery, 1...1000, "\(ctx) badge impatientHopEvery")
            }
            if let variants = s.variants {
                for (vn, v) in variants {
                    clip(v.loop, "\(ctx) variant \(vn)")
                    if let c = v.enter { clip(c, "\(ctx) variant \(vn)") }
                    if let c = v.exit { clip(c, "\(ctx) variant \(vn)") }
                    if let p = v.prop, m.props[p] == nil { bad("\(ctx) variant \(vn) references unknown prop \(p)") }
                }
                if let d = s.defaultVariant {
                    if variants[d] == nil { bad("\(ctx) defaultVariant \(d) is not a variant") }
                } else if !variants.isEmpty {
                    bad("\(ctx) has variants but no defaultVariant")
                }
            }
        }

        let i = m.interactions
        for n in [i.notice, i.pet, i.petEnd, i.press, i.boopEnd, i.held, i.drop, i.blink,
                  i.join, i.leave, i.appear, i.vanish] { clip(n, "interactions") }
        for n in [i.heldStill, i.hop, i.land, i.blinkPose, i.lookLeft, i.lookRight, i.lookUp,
                  i.lookDown, i.lookCenter] + i.walkLeft + i.walkRight { pose(n, "interactions") }
        effect(i.landDust, "interactions")
        if i.walkLeft.isEmpty || i.walkRight.isEmpty { bad("interactions walk cycles must not be empty") }

        for (name, p) in m.props {
            glyph(p.glyph, "prop \(name)")
            if p.colors.isEmpty { bad("prop \(name) has no colors") }
            for c in p.colors { color(c, "prop \(name)") }
        }

        return out
    }

    private static func isHex(_ s: String) -> Bool {
        s.count == 7 && s.first == "#" && s.dropFirst().allSatisfy(\.isHexDigit)
    }
}

/// Loads skin manifests: the builtin (always valid, embedded in the binary) and any
/// on-disk skin found by searching a list of directories in order.
public enum SkinLoader {
    /// The exact text of `Skins/clawd/manifest.json`, embedded so the builtin skin never
    /// depends on any file being present at runtime.
    public static let builtinJSON: String = #"""
{
  "schema": 2,
  "name": "clawd",
  "tickMs": 60,
  "grid": [18, 10],
  "palette": {
    "#": "#D97757",
    "o": "#1D1D1F",
    "p": "#F2A68E",
    "h": "#E4E7EB",
    "g": "#C9CED6",
    "d": "#7D848E"
  },
  "parts": {
    "body": {
      "at": [3, 0],
      "rows": ["############", "############", "############", "############", "############", "############", "############", "############"]
    },
    "eyes_open": {
      "at": [5, 2],
      "rows": ["o......o", "o......o"]
    },
    "eyes_l": {
      "at": [4, 2],
      "rows": ["o......o", "o......o"]
    },
    "eyes_r": {
      "at": [6, 2],
      "rows": ["o......o", "o......o"]
    },
    "eyes_up": {
      "at": [5, 1],
      "rows": ["o......o", "o......o"]
    },
    "eyes_down": {
      "at": [5, 3],
      "rows": ["o......o", "o......o"]
    },
    "eyes_dl": {
      "at": [4, 3],
      "rows": ["o......o", "o......o"]
    },
    "eyes_dr": {
      "at": [6, 3],
      "rows": ["o......o", "o......o"]
    },
    "eyes_half": {
      "at": [5, 3],
      "rows": ["o......o"]
    },
    "eyes_shut": {
      "at": [4, 3],
      "rows": ["oo......oo"]
    },
    "eyes_wink": {
      "at": [4, 2],
      "rows": ["........o.", "oo......o."]
    },
    "eyes_happy": {
      "at": [4, 2],
      "rows": [".o......o.", "o.o....o.o"]
    },
    "eyes_squint": {
      "at": [4, 1],
      "rows": ["o........o", ".o......o.", "o........o"]
    },
    "eyes_wide": {
      "at": [5, 1],
      "rows": ["o......o", "o......o", "o......o"]
    },
    "blush": {
      "at": [4, 4],
      "rows": ["p........p"]
    },
    "arm_l": {
      "at": [1, 4],
      "rows": ["##", "##"]
    },
    "arm_r": {
      "at": [15, 4],
      "rows": ["##", "##"]
    },
    "arm_l_up": {
      "at": [1, 2],
      "rows": ["##", "##"]
    },
    "arm_r_up": {
      "at": [15, 2],
      "rows": ["##", "##"]
    },
    "arm_l_hi": {
      "at": [1, -1],
      "rows": ["##", "##"]
    },
    "arm_r_hi": {
      "at": [15, -1],
      "rows": ["##", "##"]
    },
    "arm_l_droop": {
      "at": [1, 5],
      "rows": ["##", "##"]
    },
    "arm_l_key": {
      "at": [1, 6],
      "rows": ["##", "##"]
    },
    "arm_r_key": {
      "at": [15, 6],
      "rows": ["##", "##"]
    },
    "arm_l_keyup": {
      "at": [1, 5],
      "rows": ["##", "##"]
    },
    "arm_r_keyup": {
      "at": [15, 5],
      "rows": ["##", "##"]
    },
    "laptop": {
      "at": [3, 4],
      "rows": [".hhhhhhhhhh.", ".gggg##gggg.", ".gggg##gggg.", ".gggggggggg.", "dddddddddddd"]
    },
    "laptop_half": {
      "at": [3, 6],
      "rows": [".hhhhhhhhhh.", ".gggggggggg.", "dddddddddddd"]
    },
    "laptop_closed": {
      "at": [3, 7],
      "rows": [".hhhhhhhhhh.", "dddddddddddd"]
    },
    "arm_r_droop": {
      "at": [15, 5],
      "rows": ["##", "##"]
    },
    "legs": {
      "at": [4, 8],
      "rows": ["#.#....#.#", "#.#....#.#"]
    },
    "legs_a": {
      "at": [4, 8],
      "rows": ["#.#....#.#", ".......#.#"]
    },
    "legs_b": {
      "at": [4, 8],
      "rows": ["#.#....#.#", "#.#......."]
    },
    "legs_tuck": {
      "at": [4, 8],
      "rows": ["#.#....#.#"]
    },
    "legs_dangle_a": {
      "at": [4, 8],
      "rows": ["#.#....#.#", "#.#....#.#", "#.#......."]
    },
    "legs_dangle_b": {
      "at": [4, 8],
      "rows": ["#.#....#.#", "#.#....#.#", ".......#.#"]
    }
  },
  "poses": {
    "base": ["body", "eyes_open", "arm_l", "arm_r", "legs"],
    "half": ["body", "eyes_half", "arm_l", "arm_r", "legs"],
    "shut": ["body", "eyes_shut", "arm_l", "arm_r", "legs"],
    "look_l": ["body", "eyes_l", "arm_l", "arm_r", "legs"],
    "look_r": ["body", "eyes_r", "arm_l", "arm_r", "legs"],
    "look_up": ["body", "eyes_up", "arm_l", "arm_r", "legs"],
    "look_down": ["body", "eyes_down", "arm_l", "arm_r", "legs"],
    "read_l": ["body", "eyes_dl", "arm_l", "arm_r", "legs"],
    "read_r": ["body", "eyes_dr", "arm_l", "arm_r", "legs"],
    "wink": ["body", "eyes_wink", "arm_l", "arm_r", "legs"],
    "happy": ["body", "eyes_happy", "blush", "arm_l", "arm_r", "legs"],
    "walk_a": ["body", "eyes_open", "arm_l", "arm_r", "legs_a"],
    "walk_l_a": ["body", "eyes_l", "arm_l", "arm_r", "legs_a"],
    "walk_l_b": ["body", "eyes_l", "arm_l", "arm_r", "legs_b"],
    "walk_r_a": ["body", "eyes_r", "arm_l", "arm_r", "legs_a"],
    "walk_r_b": ["body", "eyes_r", "arm_l", "arm_r", "legs_b"],
    "walk_b": ["body", "eyes_open", "arm_l", "arm_r", "legs_b"],
    "arms_up": ["body", "eyes_open", "arm_l_up", "arm_r_up", "legs"],
    "air": ["body", "eyes_open", "arm_l_up", "arm_r_up", "legs_tuck"],
    "cheer": ["body", "eyes_happy", "blush", "arm_l_hi", "arm_r_hi", "legs_tuck"],
    "raise": ["body", "eyes_open", "arm_l", "arm_r_hi", "legs"],
    "raise_mid": ["body", "eyes_open", "arm_l", "arm_r_up", "legs"],
    "wave_hi": ["body", "eyes_happy", "arm_l", "arm_r_hi", "legs"],
    "wave_mid": ["body", "eyes_happy", "arm_l", "arm_r_up", "legs"],
    "surprised": ["body", "eyes_wide", "arm_l_up", "arm_r_up", "legs"],
    "urgent": ["body", "eyes_wide", "arm_l_hi", "arm_r_hi", "legs_tuck"],
    "sneeze": ["body", "eyes_shut", "arm_l_up", "arm_r_up", "legs"],
    "yawn": ["body", "eyes_shut", "arm_l_hi", "arm_r_hi", "legs"],
    "held_a": ["body", "eyes_squint", "arm_l_hi", "arm_r_up", "legs_dangle_a"],
    "held_b": ["body", "eyes_squint", "arm_l_up", "arm_r_hi", "legs_dangle_b"],
    "squeeze": ["body", "eyes_squint", "arm_l", "arm_r", "legs"],
    "lap_closed": ["body", "eyes_down", "arm_l_key", "arm_r_key", "legs", "laptop_closed"],
    "lap_half": ["body", "eyes_down", "arm_l_key", "arm_r_key", "legs", "laptop_half"],
    "lap_look": ["body", "eyes_open", "arm_l_key", "arm_r_key", "legs", "laptop"],
    "lap_a": ["body", "eyes_down", "arm_l_key", "arm_r_keyup", "legs", "laptop"],
    "lap_b": ["body", "eyes_down", "arm_l_keyup", "arm_r_key", "legs", "laptop"],
    "lap_enter_up": ["body", "eyes_down", "arm_l_key", "arm_r_hi", "legs", "laptop"],
    "lap_happy": ["body", "eyes_happy", "arm_l_key", "arm_r_key", "legs", "laptop"],
    "bash_a": ["body", "eyes_open", "arm_l_up", "arm_r", "legs_a"],
    "bash_b": ["body", "eyes_open", "arm_l", "arm_r_up", "legs_b"],
    "think": ["body", "eyes_up", "arm_l", "arm_r", "legs"],
    "juggle_a": ["body", "eyes_up", "arm_l_hi", "arm_r_up", "legs"],
    "juggle_b": ["body", "eyes_up", "arm_l_up", "arm_r_hi", "legs"],
    "oops": ["body", "eyes_squint", "arm_l_up", "arm_r_up", "legs"],
    "slump": ["body", "eyes_down", "arm_l_droop", "arm_r_droop", "legs"],
    "slump_shut": ["body", "eyes_shut", "arm_l_droop", "arm_r_droop", "legs"]
  },
  "glyphs": {
    "dot": ["#"],
    "puff": ["##"],
    "tilde": ["##.", ".##"],
    "spark": [".#.", "###", ".#."],
    "z": ["##.", ".#.", ".##"],
    "Z": ["####", "..#.", ".#..", "####"],
    "heart": ["#.#", "###", ".#."],
    "bang": ["##", "##", "##", "..", "##"],
    "q": ["###.", "...#", ".##.", ".#..", "....", ".#.."],
    "check": ["....#", "...##", "#.##.", "###..", ".#..."],
    "drop": [".#.", "###", "###", ".#."],
    "ball": ["##", "##"],
    "lt": [".#", "#.", ".#"],
    "gt": ["#.", ".#", "#."],
    "sl": ["..#", ".#.", "#.."],
    "s0": ["#"],
    "s1": [".#.", "###", ".#."],
    "s2": ["..#..", "..#..", "#####", "..#..", "..#.."],
    "s3": ["#.#.#", ".###.", "#####", ".###.", "#.#.#"],
    "s4": ["#.#.#", ".###.", "##.##", ".###.", "#.#.#"],
    "s5": ["##.##", "#####", ".###.", "#####", "##.##"],
    "dotbig": [".##.", "####", "####", ".##."]
  },
  "clips": {
    "idle": [
      ["base", 40],
      ["base", 10, 0, -1]
    ],
    "blink": [
      ["shut", 2]
    ],
    "double_blink": [
      ["shut", 2],
      ["base", 3],
      ["shut", 2]
    ],
    "look": [
      ["look_r", 5],
      ["look_l", 5],
      ["base", 1],
      ["shut", 1]
    ],
    "wink": [
      ["wink", 5],
      ["base", 1]
    ],
    "tap": [
      ["walk_b", 2],
      ["base", 2],
      ["walk_b", 2],
      ["base", 2],
      ["walk_b", 1],
      ["base", 1],
      ["walk_b", 1],
      ["base", 1],
      ["base", 2],
      ["shut", 1]
    ],
    "sneeze": [
      ["shut", 2],
      ["sneeze", 4, 0, 1],
      ["shut", 2, 0, -2, "puff"],
      ["base", 2, 0, -1],
      ["base", 2],
      ["shut", 1]
    ],
    "waddle": [
      ["walk_a", 2, -1, 0],
      ["walk_b", 2, -2, 0],
      ["walk_a", 2, -3, 0],
      ["walk_b", 2, -4, 0],
      ["base", 3, -4, 0],
      ["look_r", 4, -4, 0],
      ["walk_a", 2, -3, 0],
      ["walk_b", 2, -2, 0],
      ["walk_a", 2, -1, 0],
      ["walk_b", 2],
      ["walk_a", 2, 1, 0],
      ["walk_b", 2, 2, 0],
      ["base", 3, 2, 0],
      ["look_l", 4, 2, 0],
      ["walk_a", 2, 1, 0],
      ["walk_b", 2],
      ["shut", 1]
    ],
    "yawn": [
      ["shut", 3],
      ["yawn", 14, 0, 1],
      ["shut", 2, 0, -2],
      ["base", 3],
      ["shut", 1]
    ],
    "jump": [
      ["base", 1, 0, -2, "dust"],
      ["base", 1, 0, -2, "tilde"],
      ["air", 1, 0, 2],
      ["air", 2, 0, 4],
      ["air", 1, 0, 2],
      ["base", 1],
      ["base", 1, 0, -2, "dust"],
      ["base", 1, 0, -2],
      ["air", 1, 0, 2],
      ["air", 2, 0, 4],
      ["air", 1, 0, 2],
      ["base", 1],
      ["shut", 1]
    ],
    "doze": [
      ["half", 8],
      ["base", 4],
      ["half", 10],
      ["base", 3],
      ["half", 12],
      ["shut", 4, 0, -1]
    ],
    "sleep": [
      ["shut", 25, 0, 0, "zzz"],
      ["shut", 25, 0, -1]
    ],
    "wake": [
      ["surprised", 2, 0, 2, "bang_grey"],
      ["surprised", 3],
      ["look_l", 3],
      ["look_r", 3],
      ["base", 1],
      ["shut", 1]
    ],
    "work_enter": [
      ["base", 1, 0, -2, "dust"],
      ["arms_up", 1, 0, 2],
      ["arms_up", 1, 0, 1],
      ["base", 1]
    ],
    "lap_open": [
      ["base", 1, 0, -2, "dust_small"],
      ["lap_closed", 3],
      ["lap_half", 2],
      ["lap_look", 3],
      ["lap_a", 2]
    ],
    "laptop": [
      ["lap_a", 2],
      ["lap_b", 2],
      ["lap_a", 2],
      ["lap_b", 2],
      ["lap_a", 2],
      ["lap_b", 2],
      ["lap_a", 2, 0, 0, "code"],
      ["lap_b", 2],
      ["lap_a", 2],
      ["lap_b", 2],
      ["lap_look", 7],
      ["lap_a", 2],
      ["lap_b", 2],
      ["lap_a", 2],
      ["lap_b", 2],
      ["lap_a", 2, 0, 0, "code"],
      ["lap_b", 2],
      ["lap_enter_up", 3],
      ["lap_a", 1, 0, -1, "code"],
      ["lap_happy", 4],
      ["lap_b", 2],
      ["lap_a", 2]
    ],
    "lap_close": [
      ["lap_look", 1],
      ["lap_half", 2],
      ["lap_closed", 2],
      ["base", 1, 0, -2, "dust_small"],
      ["base", 1]
    ],
    "think": [
      ["think", 10],
      ["think", 10, 0, -1],
      ["think", 10],
      ["look_r", 4],
      ["look_l", 4],
      ["think", 6, 0, -1]
    ],
    "read": [
      ["read_l", 3],
      ["look_down", 3],
      ["read_r", 5],
      ["read_l", 1],
      ["look_down", 3],
      ["read_r", 5],
      ["shut", 1]
    ],
    "bash": [
      ["bash_a", 2, -1, 0],
      ["bash_b", 2],
      ["bash_a", 2, 1, 0],
      ["bash_b", 2]
    ],
    "juggle": [
      ["juggle_a", 3],
      ["juggle_b", 3]
    ],
    "alert": [
      ["surprised", 2],
      ["surprised", 1, 0, 2],
      ["surprised", 2, 0, 3],
      ["surprised", 1, 0, 2],
      ["base", 1, 0, -2, "dust"],
      ["raise", 2]
    ],
    "ask": [
      ["raise", 5],
      ["raise_mid", 3],
      ["raise", 5],
      ["raise_mid", 3],
      ["raise", 5],
      ["base", 16],
      ["shut", 1],
      ["base", 10]
    ],
    "impatient": [
      ["walk_b", 2],
      ["base", 2],
      ["walk_b", 2],
      ["base", 2],
      ["walk_b", 1],
      ["base", 1],
      ["walk_b", 1],
      ["base", 1],
      ["walk_b", 1],
      ["base", 1],
      ["raise", 3],
      ["raise_mid", 2],
      ["raise", 3],
      ["raise_mid", 2],
      ["base", 1, 0, -2, "dust"],
      ["urgent", 2, 0, 3],
      ["urgent", 1, 0, 1],
      ["base", 6]
    ],
    "celebrate": [
      ["base", 1, 0, -2, "dust"],
      ["base", 1, 0, -2, "tilde"],
      ["cheer", 1, 0, 2],
      ["cheer", 2, 0, 4, "confetti"],
      ["cheer", 1, 0, 2],
      ["happy", 1],
      ["happy", 1, 0, -2, "dust"],
      ["cheer", 1, 0, 2],
      ["cheer", 2, 0, 4],
      ["cheer", 1, 0, 2],
      ["happy", 3, 0, -2],
      ["happy", 1, 0, -1],
      ["happy", 8]
    ],
    "content": [
      ["happy", 30],
      ["base", 25],
      ["shut", 1],
      ["base", 20],
      ["look_r", 5],
      ["look_l", 5],
      ["shut", 1],
      ["happy", 10, 0, -1]
    ],
    "seen": [
      ["happy", 3],
      ["base", 2]
    ],
    "oops": [
      ["oops", 1, 1, 0, "bang_err"],
      ["oops", 1, -1, 0],
      ["oops", 1, 1, 0],
      ["oops", 1, -1, 0],
      ["oops", 1, 1, 0],
      ["oops", 1, -1, 0],
      ["oops", 3],
      ["slump", 4, 0, -1, "sweat"]
    ],
    "slump": [
      ["slump", 40, 0, -1],
      ["slump_shut", 2, 0, -1],
      ["slump", 30, 0, -1],
      ["slump_shut", 3, 0, -2, "sigh"],
      ["slump", 10, 0, -1]
    ],
    "notice": [
      ["arms_up", 1, 0, 1],
      ["base", 1]
    ],
    "pet": [
      ["happy", 3, 0, 0, "heart"],
      ["happy", 3, 0, -1]
    ],
    "pet_end": [
      ["happy", 8],
      ["shut", 1]
    ],
    "press": [
      ["squeeze", 1, 0, -2, "dust"],
      ["squeeze", 200, 0, -2]
    ],
    "boop_end": [
      ["look_l", 5],
      ["base", 1],
      ["shut", 1]
    ],
    "held": [
      ["held_a", 2],
      ["held_b", 2]
    ],
    "drop": [
      ["air", 1, 0, 2],
      ["base", 2, 0, -2, "dust"],
      ["base", 1, 0, -1],
      ["look_l", 2],
      ["look_r", 2],
      ["base", 1],
      ["shut", 1]
    ],
    "peekaboo": [
      ["base", 3, 0, -10],
      ["look_l", 5, 0, -6],
      ["look_r", 5, 0, -6],
      ["look_l", 3, 0, -6],
      ["arms_up", 1, 0, -2],
      ["arms_up", 2, 0, 2, "dust"],
      ["arms_up", 2, 0, 1],
      ["base", 1],
      ["shut", 1],
      ["base", 2]
    ],
    "leave": [
      ["wave_hi", 3],
      ["wave_mid", 2],
      ["wave_hi", 3],
      ["wave_mid", 2],
      ["wave_hi", 3],
      ["base", 2],
      ["base", 2, 0, -2, "dust"],
      ["look_l", 3, 0, -6],
      ["look_r", 3, 0, -6],
      ["base", 2, 0, -8],
      ["base", 2, 0, -10, "poof"]
    ],
    "appear": [
      ["arms_up", 1, 0, 16],
      ["arms_up", 1, 0, 12],
      ["arms_up", 1, 0, 7],
      ["arms_up", 1, 0, 2],
      ["base", 2, 0, -2, "dust"],
      ["base", 1, 0, -1],
      ["base", 2],
      ["shut", 1]
    ],
    "vanish": [
      ["base", 1, 0, -2, "dust"],
      ["look_l", 2, 0, -6],
      ["base", 2, 0, -8],
      ["base", 2, 0, -10, "poof"]
    ]
  },
  "effects": {
    "dust": {
      "particles": [
        {
          "glyph": "dot",
          "color": "#B4BAC4",
          "x": 2,
          "y": 9,
          "vx": -12,
          "vy": -3,
          "life": 4
        },
        {
          "glyph": "dot",
          "color": "#B4BAC4",
          "x": 15,
          "y": 9,
          "vx": 12,
          "vy": -3,
          "life": 4
        }
      ]
    },
    "dust_small": {
      "particles": [
        {
          "glyph": "dot",
          "color": "#B4BAC4",
          "x": 3,
          "y": 9,
          "vx": -8,
          "vy": -2,
          "life": 3
        },
        {
          "glyph": "dot",
          "color": "#B4BAC4",
          "x": 14,
          "y": 9,
          "vx": 8,
          "vy": -2,
          "life": 3
        }
      ]
    },
    "tilde": {
      "particles": [
        {
          "glyph": "tilde",
          "color": "#B4BAC4",
          "x": -1,
          "y": 8,
          "vx": -6,
          "vy": -2,
          "life": 5
        },
        {
          "glyph": "tilde",
          "color": "#B4BAC4",
          "x": 16,
          "y": 8,
          "vx": 6,
          "vy": -2,
          "life": 5
        }
      ]
    },
    "puff": {
      "particles": [
        {
          "glyph": "tilde",
          "color": "#B4BAC4",
          "x": 16,
          "y": 3,
          "vx": 10,
          "vy": -3,
          "life": 6
        }
      ]
    },
    "sigh": {
      "particles": [
        {
          "glyph": "tilde",
          "color": "#A3A9B4",
          "x": 15,
          "y": 5,
          "vx": 5,
          "vy": -2,
          "life": 9
        }
      ]
    },
    "confetti": {
      "particles": [
        {
          "count": 16,
          "glyph": "dot",
          "colors": ["#D97757", "#34C759", "#FFD60A", "#64D2FF", "#FF7096", "#F2F2F7"],
          "x": [5, 12],
          "y": -1,
          "vx": [-18, 18],
          "vy": [-34, -16],
          "ay": 80,
          "life": [13, 19]
        }
      ]
    },
    "zzz": {
      "cycle": [
        [
          {
            "glyph": "z",
            "color": "#A3A9B4",
            "x": 15,
            "y": -2,
            "vx": 3,
            "vy": -5,
            "sway": 1,
            "life": 30
          }
        ],
        [
          {
            "glyph": "Z",
            "color": "#A3A9B4",
            "x": 15,
            "y": -2,
            "vx": 3,
            "vy": -5,
            "sway": 1,
            "life": 30
          }
        ]
      ]
    },
    "heart": {
      "particles": [
        {
          "glyph": "heart",
          "color": "#FF7096",
          "x": [3, 13],
          "y": -2,
          "vx": [-2, 2],
          "vy": -11,
          "life": 10
        }
      ]
    },
    "code": {
      "cycle": [
        [
          {
            "glyph": "sl",
            "color": "#DDE1E7",
            "x": 1,
            "y": 1,
            "vx": -4,
            "vy": -7,
            "life": 9
          }
        ],
        [
          {
            "glyph": "gt",
            "color": "#DDE1E7",
            "x": 15,
            "y": 1,
            "vx": 4,
            "vy": -7,
            "life": 9
          }
        ],
        [
          {
            "glyph": "lt",
            "color": "#DDE1E7",
            "x": 15,
            "y": 1,
            "vx": 4,
            "vy": -7,
            "life": 9
          }
        ]
      ]
    },
    "bang_err": {
      "particles": [
        {
          "glyph": "bang",
          "color": "#FF3B30",
          "x": 16,
          "y": -7,
          "pop": true,
          "life": 10
        }
      ]
    },
    "bang_grey": {
      "particles": [
        {
          "glyph": "bang",
          "color": "#E5E7EB",
          "x": 16,
          "y": -7,
          "pop": true,
          "life": 7
        }
      ]
    },
    "sweat": {
      "particles": [
        {
          "glyph": "drop",
          "color": "#86C8FF",
          "x": 15,
          "y": -2,
          "vx": 0,
          "vy": 4,
          "life": 14
        }
      ]
    },
    "poof": {
      "particles": [
        {
          "glyph": "dot",
          "color": "#B4BAC4",
          "x": 8,
          "y": 6,
          "vx": 16,
          "vy": -4,
          "life": 6
        },
        {
          "glyph": "spark",
          "color": "#B4BAC4",
          "x": 8,
          "y": 6,
          "vx": 11.31,
          "vy": 3.07,
          "life": 6
        },
        {
          "glyph": "dot",
          "color": "#B4BAC4",
          "x": 8,
          "y": 6,
          "vx": 0,
          "vy": 6,
          "life": 6
        },
        {
          "glyph": "spark",
          "color": "#B4BAC4",
          "x": 8,
          "y": 6,
          "vx": -11.31,
          "vy": 3.07,
          "life": 6
        },
        {
          "glyph": "dot",
          "color": "#B4BAC4",
          "x": 8,
          "y": 6,
          "vx": -16,
          "vy": -4,
          "life": 6
        },
        {
          "glyph": "spark",
          "color": "#B4BAC4",
          "x": 8,
          "y": 6,
          "vx": -11.31,
          "vy": -11.07,
          "life": 6
        },
        {
          "glyph": "dot",
          "color": "#B4BAC4",
          "x": 8,
          "y": 6,
          "vx": 0,
          "vy": -14,
          "life": 6
        },
        {
          "glyph": "spark",
          "color": "#B4BAC4",
          "x": 8,
          "y": 6,
          "vx": 11.31,
          "vy": -11.07,
          "life": 6
        }
      ]
    },
    "twinkle": {
      "particles": [
        {
          "glyph": "spark",
          "color": "#E9EDF2",
          "x": 14,
          "y": -9,
          "life": 6,
          "shrinkTo": "dot"
        }
      ]
    }
  },
  "accessories": {
    "spinner": {
      "frames": ["s0", "s1", "s2", "s3", "s4", "s5"],
      "color": "#D97757",
      "periodMs": 2000,
      "box": 5,
      "reduced": "dotbig"
    },
    "q": {
      "glyph": "q",
      "color": "#FF9F0A",
      "bobEvery": 7
    },
    "check": {
      "glyph": "check",
      "color": "#34C759",
      "twinkleEvery": 43,
      "twinkle": "twinkle"
    },
    "bang": {
      "glyph": "bang",
      "color": "#FF3B30"
    }
  },
  "states": {
    "idle": {
      "loop": "idle",
      "tint": "dim",
      "still": "base",
      "fidget": {
        "every": [60, 160],
        "pick": [
          ["blink", 6],
          ["double_blink", 2],
          ["look", 4],
          ["wink", 1],
          ["tap", 2],
          ["sneeze", 1],
          ["waddle", 2],
          ["yawn", 1],
          ["jump", 1]
        ]
      },
      "sleep": {
        "after": 2000,
        "doze": "doze",
        "loop": "sleep",
        "wake": "wake",
        "still": "shut"
      }
    },
    "running": {
      "enter": "work_enter",
      "accessory": "spinner",
      "still": "lap_a",
      "defaultVariant": "laptop",
      "fidget": {
        "every": [90, 220],
        "pick": [
          ["blink", 1]
        ]
      },
      "variants": {
        "laptop": {
          "loop": "laptop",
          "enter": "lap_open",
          "exit": "lap_close"
        },
        "think": {
          "loop": "think"
        },
        "read": {
          "loop": "read"
        },
        "bash": {
          "loop": "bash"
        },
        "juggle": {
          "loop": "juggle",
          "prop": "juggle"
        }
      }
    },
    "waiting": {
      "enter": "alert",
      "loop": "ask",
      "accessory": "q",
      "still": "raise",
      "badge": {
        "glyph": "bang",
        "color": "#FF9F0A",
        "x": 16,
        "hopEvery": 20,
        "impatientHopEvery": 8
      },
      "impatient": {
        "after": 500,
        "loop": "impatient"
      }
    },
    "done": {
      "enter": "celebrate",
      "loop": "content",
      "accessory": "check",
      "still": "happy",
      "seen": "seen",
      "fidget": {
        "every": [90, 220],
        "pick": [
          ["wink", 1],
          ["look", 1]
        ]
      }
    },
    "error": {
      "enter": "oops",
      "loop": "slump",
      "tint": "dim",
      "accessory": "bang",
      "still": "slump",
      "stillDy": -1
    }
  },
  "interactions": {
    "notice": "notice",
    "pet": "pet",
    "petEnd": "pet_end",
    "press": "press",
    "boopEnd": "boop_end",
    "held": "held",
    "heldStill": "held_a",
    "drop": "drop",
    "blink": "blink",
    "join": "peekaboo",
    "leave": "leave",
    "appear": "appear",
    "vanish": "vanish",
    "hop": "air",
    "land": "base",
    "blinkPose": "shut",
    "landDust": "dust_small",
    "walkLeft": ["walk_l_a", "walk_l_b"],
    "walkRight": ["walk_r_a", "walk_r_b"],
    "lookLeft": "look_l",
    "lookRight": "look_r",
    "lookUp": "look_up",
    "lookDown": "look_down",
    "lookCenter": "base"
  },
  "props": {
    "juggle": {
      "glyph": "ball",
      "colors": ["#D97757", "#F0A487", "#D97757"]
    }
  }
}

"""#

    public static func builtin() -> SkinManifest {
        // `builtinJSON` is a fixed, valid literal covered by `builtinIsValidSchema2` and
        // `bundledManifestIsTheDesignCopy`, so decoding it can never fail in practice.
        try! JSONDecoder().decode(SkinManifest.self, from: Data(builtinJSON.utf8))
    }

    /// Searches `searchDirs` in order for `<dir>/<name>/manifest.json`; the first one that
    /// both decodes and passes `SkinValidator.problems` wins. Falls back to `builtin()` if
    /// none qualifies.
    public static func load(name: String, searchDirs: [URL]) -> SkinManifest {
        find(name: name, searchDirs: searchDirs) ?? builtin()
    }

    /// `load` without the fallback: nil if no search dir has a valid skin called `name`.
    public static func find(name: String, searchDirs: [URL]) -> SkinManifest? {
        searchDirs.lazy.compactMap { validManifest(in: $0.appendingPathComponent(name)) }.first
    }

    /// The manifest in skin folder `dir`, if it decodes and passes `SkinValidator.problems`.
    static func validManifest(in dir: URL) -> SkinManifest? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(SkinManifest.self, from: data),
              SkinValidator.problems(manifest).isEmpty
        else {
            return nil
        }
        return manifest
    }
}
