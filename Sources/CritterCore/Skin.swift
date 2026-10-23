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
    /// The exact text of `Skins/sprig/manifest.json`, embedded so the builtin skin never
    /// depends on any file being present at runtime.
    public static let builtinJSON: String = #"""
{
  "schema": 2,
  "name": "sprig",
  "title": "小芽 Sprig",
  "tickMs": 60,
  "grid": [18, 10],
  "palette": {
    "B": "#B39DF3",
    "b": "#9580DD",
    "h": "#CDBDFA",
    "G": "#6BCB5F",
    "g": "#3F9442",
    "f": "#FF8FB8",
    "y": "#FFD24A",
    "o": "#2A2140",
    "w": "#FFFFFF",
    "p": "#F7A1C0",
    "m": "#5B3A8E",
    "l": "#E4E7EB",
    "s": "#C9CED6",
    "d": "#7D848E",
    "r": "#C98F3E",
    "e": "#CFEFFF"
  },
  "parts": {
    "body": {
      "at": [2, 0],
      "rows": ["..BBBBBBBBBB..", ".BhhBBBBBBBBB.", "BhBBBBBBBBBBBB", "BBBBBBBBBBBBBB", "BBBBBBBBBBBBBB", "BBBBBBBBBBBBBB", "BBBBBBBBBBBBBB", ".bBBBBBBBBBBb.", "..bbbbbbbbbb.."]
    },
    "body_squash": {
      "at": [1, 1],
      "rows": ["...BBBBBBBBBB...", ".BhhBBBBBBBBBBB.", "BhBBBBBBBBBBBBBB", "BBBBBBBBBBBBBBBB", "BBBBBBBBBBBBBBBB", "BBBBBBBBBBBBBBBB", ".bBBBBBBBBBBBBb.", "..bbbbbbbbbbbb.."]
    },
    "body_tall": {
      "at": [3, -1],
      "rows": ["..BBBBBBBB..", ".BhhBBBBBBB.", "BhBBBBBBBBBB", "BBBBBBBBBBBB", "BBBBBBBBBBBB", "BBBBBBBBBBBB", "BBBBBBBBBBBB", "BBBBBBBBBBBB", ".bBBBBBBBBb.", "..bbbbbbbb.."]
    },
    "top": {
      "at": [5, -2],
      "rows": ["GGG..GGG", ".GGggGG."]
    },
    "top_low": {
      "at": [5, -1],
      "rows": ["GGG..GGG", ".GGggGG."]
    },
    "top_up": {
      "at": [6, -2],
      "rows": ["GG..GG", ".GggG."]
    },
    "top_up_tall": {
      "at": [6, -3],
      "rows": ["GG..GG", ".GggG."]
    },
    "top_droop": {
      "at": [6, -2],
      "rows": ["..gg..", "GGggGG", "G....G"]
    },
    "top_flat_low": {
      "at": [4, 0],
      "rows": ["GGGGggGGGG"]
    },
    "top_sway_l": {
      "at": [4, -2],
      "rows": ["GGG..GGG.", "..GGggGG."]
    },
    "top_sway_r": {
      "at": [5, -2],
      "rows": [".GGG..GGG", ".GGggGG.."]
    },
    "top_edge": {
      "at": [7, -2],
      "rows": [".GG.", ".gg."]
    },
    "top_bud": {
      "at": [7, -2],
      "rows": [".GG.", "GggG"]
    },
    "top_bud_low": {
      "at": [7, -1],
      "rows": [".GG.", "GggG"]
    },
    "top_bloom": {
      "at": [4, -2],
      "rows": ["GGG.ff.GGG", "..GfyyfG.."]
    },
    "top_bloom_l": {
      "at": [3, -2],
      "rows": ["GGG.ff.GGG.", "...GfyyfG.."]
    },
    "top_bloom_r": {
      "at": [4, -2],
      "rows": [".GGG.ff.GGG", "..GfyyfG..."]
    },
    "top_bloom_low": {
      "at": [4, -1],
      "rows": ["GGG.ff.GGG", "..GfyyfG.."]
    },
    "top_bloom_tall": {
      "at": [4, -3],
      "rows": ["GGG.ff.GGG", "..GfyyfG.."]
    },
    "eyes_open": {
      "at": [5, 4],
      "rows": ["wo....wo", "oo....oo"]
    },
    "eyes_l": {
      "at": [4, 4],
      "rows": ["wo....wo", "oo....oo"]
    },
    "eyes_r": {
      "at": [6, 4],
      "rows": ["wo....wo", "oo....oo"]
    },
    "eyes_up": {
      "at": [5, 3],
      "rows": ["wo....wo", "oo....oo"]
    },
    "eyes_down": {
      "at": [5, 5],
      "rows": ["wo....wo", "oo....oo"]
    },
    "eyes_ul": {
      "at": [4, 3],
      "rows": ["wo....wo", "oo....oo"]
    },
    "eyes_ur": {
      "at": [6, 3],
      "rows": ["wo....wo", "oo....oo"]
    },
    "eyes_half": {
      "at": [5, 5],
      "rows": ["oo....oo"]
    },
    "eyes_shut": {
      "at": [4, 5],
      "rows": ["ooo....ooo"]
    },
    "eyes_happy": {
      "at": [5, 4],
      "rows": ["wo....wo", "oo....oo"]
    },
    "eyes_squint": {
      "at": [5, 3],
      "rows": ["o......o", ".o....o.", "o......o"]
    },
    "eyes_wide": {
      "at": [5, 3],
      "rows": ["wo....wo", "oo....oo", "oo....oo"]
    },
    "eyes_wink": {
      "at": [5, 4],
      "rows": ["wo....oo.", "oo...o..o"]
    },
    "eyes_dizzy": {
      "at": [4, 3],
      "rows": ["o.o....o.o", ".o......o.", "o.o....o.o"]
    },
    "eye_l_only": {
      "at": [5, 4],
      "rows": ["wo", "oo"]
    },
    "eye_r_only": {
      "at": [11, 4],
      "rows": ["wo", "oo"]
    },
    "blush": {
      "at": [4, 6],
      "rows": ["pp......pp"]
    },
    "mouth_o": {
      "at": [8, 6],
      "rows": ["mm", "mm"]
    },
    "mouth_dot": {
      "at": [8, 6],
      "rows": ["mm"]
    },
    "mouth_smile": {
      "at": [7, 6],
      "rows": ["m..m", ".mm."]
    },
    "mouth_open": {
      "at": [7, 6],
      "rows": ["mmmm", ".mm."]
    },
    "mouth_frown": {
      "at": [7, 6],
      "rows": [".mm.", "m..m"]
    },
    "feet": {
      "at": [4, 9],
      "rows": ["bbb....bbb"]
    },
    "feet_a": {
      "at": [4, 9],
      "rows": [".......bbb"]
    },
    "feet_b": {
      "at": [4, 9],
      "rows": ["bbb......."]
    },
    "feet_tuck": {
      "at": [5, 9],
      "rows": ["bb....bb"]
    },
    "feet_wide": {
      "at": [3, 9],
      "rows": ["bbb......bbb"]
    },
    "feet_dangle_a": {
      "at": [4, 9],
      "rows": ["bb......bb", "bb........"]
    },
    "feet_dangle_b": {
      "at": [4, 9],
      "rows": ["bb......bb", "........bb"]
    },
    "laptop": {
      "at": [3, 6],
      "rows": [".llllllllll.", ".ssssGGssss.", ".ssssssssss.", "dddddddddddd"]
    },
    "laptop_half": {
      "at": [3, 8],
      "rows": [".llllllllll.", "dddddddddddd"]
    },
    "laptop_closed": {
      "at": [3, 9],
      "rows": ["dddddddddddd"]
    },
    "lens_r": {
      "at": [9, 2],
      "rows": [".rrrr..", "reeeer.", "reower.", "reooer.", "reeeer.", ".rrrrr.", ".....rr"]
    },
    "lens_l": {
      "at": [2, 2],
      "rows": ["..rrrr.", ".reeeer", ".rewoer", ".reooer", ".reeeer", ".rrrrr.", "rr....."]
    },
    "arm_l": {
      "at": [1, 5],
      "rows": ["B", "B"]
    },
    "arm_r": {
      "at": [16, 5],
      "rows": ["B", "B"]
    },
    "arm_l_up": {
      "at": [0, 3],
      "rows": ["B.", ".B"]
    },
    "arm_r_up": {
      "at": [16, 3],
      "rows": [".B", "B."]
    },
    "arm_l_hi": {
      "at": [0, 0],
      "rows": ["B.", ".B", ".B"]
    },
    "arm_r_hi": {
      "at": [16, 0],
      "rows": [".B", "B.", "B."]
    },
    "arm_l_out": {
      "at": [0, 4],
      "rows": ["BB"]
    },
    "arm_r_out": {
      "at": [16, 4],
      "rows": ["BB"]
    },
    "arm_l_droop": {
      "at": [1, 6],
      "rows": ["B.", ".B"]
    },
    "arm_r_droop": {
      "at": [15, 6],
      "rows": [".B", "B."]
    },
    "arm_l_key": {
      "at": [1, 7],
      "rows": ["BB"]
    },
    "arm_r_key": {
      "at": [15, 7],
      "rows": ["BB"]
    },
    "arm_l_keyup": {
      "at": [1, 6],
      "rows": ["BB"]
    },
    "arm_r_keyup": {
      "at": [15, 6],
      "rows": ["BB"]
    },
    "arm_l_sq": {
      "at": [0, 5],
      "rows": ["B", "B"]
    },
    "arm_r_sq": {
      "at": [17, 5],
      "rows": ["B", "B"]
    },
    "arm_l_tall": {
      "at": [2, 4],
      "rows": ["B", "B"]
    },
    "arm_r_tall": {
      "at": [15, 4],
      "rows": ["B", "B"]
    },
    "arm_l_tallhi": {
      "at": [1, 0],
      "rows": ["B.", "B.", ".B"]
    },
    "arm_r_tallhi": {
      "at": [15, 0],
      "rows": [".B", ".B", "B."]
    },
    "arm_l_pump": {
      "at": [0, 4],
      "rows": ["B.", ".B"]
    },
    "arm_r_pump": {
      "at": [16, 4],
      "rows": [".B", "B."]
    },
    "arm_l_back": {
      "at": [1, 6],
      "rows": ["B", "B"]
    },
    "arm_r_back": {
      "at": [16, 6],
      "rows": ["B", "B"]
    }
  },
  "poses": {
    "base": ["body", "feet", "arm_l", "arm_r", "eyes_open", "top"],
    "half": ["body", "feet", "arm_l", "arm_r", "eyes_half", "top"],
    "shut": ["body", "feet", "arm_l", "arm_r", "eyes_shut", "top"],
    "look_l": ["body", "feet", "arm_l", "arm_r", "eyes_l", "top"],
    "look_r": ["body", "feet", "arm_l", "arm_r", "eyes_r", "top"],
    "look_up": ["body", "feet", "arm_l", "arm_r", "eyes_up", "top"],
    "look_down": ["body", "feet", "arm_l", "arm_r", "eyes_down", "top"],
    "sway_l": ["body", "feet", "arm_l", "arm_r", "eyes_open", "top_sway_l"],
    "sway_r": ["body", "feet", "arm_l", "arm_r", "eyes_open", "top_sway_r"],
    "breathe": ["body_squash", "feet_wide", "arm_l_sq", "arm_r_sq", "eyes_open", "top_low"],
    "wink": ["body", "feet", "arm_l", "arm_r", "eyes_wink", "blush", "top_sway_r"],
    "happy": ["body", "feet", "arm_l", "arm_r", "eyes_happy", "blush", "mouth_smile", "top"],
    "happy_l": ["body", "feet", "arm_l", "arm_r", "eyes_happy", "blush", "mouth_smile", "top_sway_l"],
    "happy_r": ["body", "feet", "arm_l", "arm_r", "eyes_happy", "blush", "mouth_smile", "top_sway_r"],
    "sun": ["body", "feet", "arm_l", "arm_r", "eyes_happy", "blush", "top_up"],
    "walk_b": ["body", "feet_b", "arm_l", "arm_r", "eyes_open", "top_sway_r"],
    "walk_l_a": ["body", "feet_a", "arm_l", "arm_r", "eyes_l", "top_sway_r"],
    "walk_l_b": ["body", "feet_b", "arm_l", "arm_r", "eyes_l", "top_sway_r"],
    "walk_r_a": ["body", "feet_a", "arm_l", "arm_r", "eyes_r", "top_sway_l"],
    "walk_r_b": ["body", "feet_b", "arm_l", "arm_r", "eyes_r", "top_sway_l"],
    "attn": ["body", "feet", "arm_l", "arm_r", "eyes_open", "top_up"],
    "attn_shut": ["body", "feet", "arm_l", "arm_r", "eyes_shut", "top_up"],
    "attn_tap": ["body", "feet_b", "arm_l", "arm_r", "eyes_open", "top_up"],
    "perk": ["body", "feet", "arm_l_up", "arm_r_up", "eyes_open", "top_up"],
    "air": ["body", "feet_tuck", "arm_l_up", "arm_r_up", "eyes_open", "top_up"],
    "squash": ["body_squash", "feet_wide", "arm_l_sq", "arm_r_sq", "eyes_open", "top_flat_low"],
    "squash_happy": ["body_squash", "feet_wide", "arm_l_sq", "arm_r_sq", "eyes_happy", "blush", "top_bloom_low"],
    "squeeze": ["body_squash", "feet_wide", "arm_l_sq", "arm_r_sq", "eyes_squint", "top_flat_low"],
    "spring": ["body_tall", "feet_tuck", "arm_l_tallhi", "arm_r_tallhi", "eyes_open", "top_up_tall"],
    "cheer": ["body_tall", "feet_tuck", "arm_l_tallhi", "arm_r_tallhi", "eyes_happy", "blush", "mouth_open", "top_bloom_tall"],
    "urgent": ["body_tall", "feet_tuck", "arm_l_tallhi", "arm_r_tallhi", "eyes_wide", "mouth_o", "top_up_tall"],
    "yawn": ["body_tall", "feet", "arm_l_tallhi", "arm_r_tallhi", "eyes_shut", "mouth_o", "top_up_tall"],
    "sneeze_in": ["body_tall", "feet", "arm_l_tall", "arm_r_tall", "eyes_shut", "mouth_o", "top_up_tall"],
    "sneeze": ["body_squash", "feet_wide", "arm_l_sq", "arm_r_sq", "eyes_shut", "mouth_dot", "top_flat_low"],
    "surprised": ["body", "feet", "arm_l_up", "arm_r_up", "eyes_wide", "mouth_o", "top_up"],
    "raise": ["body", "feet", "arm_l", "arm_r_hi", "eyes_open", "top_up"],
    "raise_mid": ["body", "feet", "arm_l", "arm_r_out", "eyes_open", "top_up"],
    "wave_hi": ["body", "feet", "arm_l", "arm_r_hi", "eyes_happy", "mouth_smile", "top_sway_r"],
    "wave_mid": ["body", "feet", "arm_l", "arm_r_out", "eyes_happy", "mouth_smile", "top_sway_l"],
    "held_a": ["body", "feet_dangle_a", "arm_l_hi", "arm_r_up", "eyes_squint", "top_sway_l"],
    "held_b": ["body", "feet_dangle_b", "arm_l_up", "arm_r_hi", "eyes_squint", "top_sway_r"],
    "lap_closed": ["body", "feet", "arm_l_key", "arm_r_key", "eyes_down", "laptop_closed", "top"],
    "lap_half": ["body", "feet", "arm_l_key", "arm_r_key", "eyes_down", "laptop_half", "top"],
    "lap_look": ["body", "feet", "arm_l_key", "arm_r_key", "eyes_open", "laptop", "top"],
    "lap_a": ["body", "feet", "arm_l_key", "arm_r_keyup", "eyes_half", "laptop", "top_sway_l"],
    "lap_b": ["body", "feet", "arm_l_keyup", "arm_r_key", "eyes_half", "laptop", "top_sway_r"],
    "lap_enter_up": ["body", "feet", "arm_l_key", "arm_r_hi", "eyes_half", "laptop", "top_up"],
    "lap_happy": ["body", "feet", "arm_l_key", "arm_r_key", "eyes_happy", "laptop", "top_up"],
    "think": ["body", "feet", "arm_l", "arm_r", "eyes_ur", "top"],
    "think_edge": ["body", "feet", "arm_l", "arm_r", "eyes_ur", "top_edge"],
    "think_l": ["body", "feet", "arm_l", "arm_r", "eyes_ul", "top"],
    "read_r": ["body", "feet", "arm_l", "arm_r_droop", "eye_l_only", "lens_r", "top"],
    "read_l": ["body", "feet", "arm_l_droop", "arm_r", "eye_r_only", "lens_l", "top"],
    "jog_a": ["body", "feet_a", "arm_l_pump", "arm_r_back", "eyes_r", "top_sway_l"],
    "jog_b": ["body", "feet_b", "arm_l_back", "arm_r_pump", "eyes_r", "top_sway_r"],
    "juggle_a": ["body", "feet", "arm_l_hi", "arm_r_up", "eyes_up", "top_sway_l"],
    "juggle_b": ["body", "feet", "arm_l_up", "arm_r_hi", "eyes_up", "top_sway_r"],
    "oops": ["body", "feet", "arm_l_up", "arm_r_up", "eyes_dizzy", "mouth_frown", "top_up"],
    "slump": ["body", "feet", "arm_l_droop", "arm_r_droop", "eyes_down", "mouth_frown", "top_droop"],
    "slump_shut": ["body", "feet", "arm_l_droop", "arm_r_droop", "eyes_shut", "mouth_frown", "top_droop"],
    "doze": ["body", "feet", "arm_l", "arm_r", "eyes_half", "top_droop"],
    "sleep": ["body", "feet", "arm_l_droop", "arm_r_droop", "eyes_shut", "top_bud"],
    "sleep_b": ["body_squash", "feet_wide", "arm_l_sq", "arm_r_sq", "eyes_shut", "top_bud_low"],
    "bloom": ["body", "feet", "arm_l", "arm_r", "eyes_happy", "blush", "mouth_smile", "top_bloom"],
    "bloom_open": ["body", "feet", "arm_l", "arm_r", "eyes_open", "blush", "top_bloom"],
    "bloom_shut": ["body", "feet", "arm_l", "arm_r", "eyes_shut", "blush", "top_bloom"],
    "bloom_wink": ["body", "feet", "arm_l", "arm_r", "eyes_wink", "blush", "top_bloom_r"],
    "bloom_l": ["body", "feet", "arm_l", "arm_r", "eyes_l", "blush", "top_bloom"],
    "bloom_r": ["body", "feet", "arm_l", "arm_r", "eyes_r", "blush", "top_bloom"],
    "bloom_up": ["body", "feet", "arm_l", "arm_r", "eyes_up", "blush", "top_bloom"],
    "bloom_down": ["body", "feet", "arm_l", "arm_r", "eyes_down", "blush", "top_bloom"],
    "bloom_sl": ["body", "feet", "arm_l", "arm_r", "eyes_open", "blush", "top_bloom_l"],
    "bloom_sr": ["body", "feet", "arm_l", "arm_r", "eyes_open", "blush", "top_bloom_r"]
  },
  "glyphs": {
    "dot": ["#"],
    "tilde": ["##.", ".##"],
    "spark": [".#.", "###", ".#."],
    "z": ["##.", ".#.", ".##"],
    "Z": ["####", "..#.", ".#..", "####"],
    "heart": ["#.#", "###", ".#."],
    "bang": ["##", "##", "##", "..", "##"],
    "q": ["###.", "...#", ".##.", ".#..", "....", ".#.."],
    "check": ["....#", "...##", "#.##.", "###..", ".#..."],
    "drop": [".#.", "###", "###", ".#."],
    "seed": ["##", "##"],
    "lt": [".#", "#.", ".#"],
    "gt": ["#.", ".#", "#."],
    "sl": ["..#", ".#.", "#.."],
    "sun0": ["#"],
    "sun1": [".#.", "###", ".#."],
    "sun2": ["###", "###", "###"],
    "sun3": ["...#...", ".......", "..###..", "#.###.#", "..###..", ".......", "...#..."],
    "sun4": ["#..#..#", ".......", "..###..", "#.###.#", "..###..", ".......", "#..#..#"],
    "shed": [".##", "##."]
  },
  "clips": {
    "idle": [
      ["base", 40],
      ["breathe", 7],
      ["base", 34],
      ["sway_l", 3],
      ["base", 2],
      ["sway_r", 3],
      ["base", 2]
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
      ["look_l", 6],
      ["base", 2],
      ["look_r", 6],
      ["base", 1],
      ["shut", 1]
    ],
    "wink": [
      ["wink", 6],
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
      ["base", 3],
      ["shut", 1]
    ],
    "sneeze": [
      ["shut", 2],
      ["sneeze_in", 3],
      ["sneeze_in", 4, 0, 1],
      ["sneeze", 2, 0, 0, "puff"],
      ["sneeze", 2],
      ["breathe", 2],
      ["base", 2],
      ["shut", 1]
    ],
    "stroll": [
      ["walk_l_a", 2, -1, 1],
      ["walk_l_b", 2, -2, 0],
      ["walk_l_a", 2, -3, 1],
      ["walk_l_b", 2, -4, 0],
      ["look_l", 5, -4, 0],
      ["base", 2, -4, 0],
      ["walk_r_a", 2, -3, 1],
      ["walk_r_b", 2, -2, 0],
      ["walk_r_a", 2, -1, 1],
      ["walk_r_b", 2],
      ["walk_r_a", 2, 1, 1],
      ["walk_r_b", 2, 2, 0],
      ["look_r", 5, 2, 0],
      ["base", 2, 2, 0],
      ["walk_l_a", 2, 1, 1],
      ["walk_l_b", 2],
      ["shut", 1]
    ],
    "yawn": [
      ["shut", 3],
      ["yawn", 14],
      ["shut", 3],
      ["breathe", 3],
      ["base", 2],
      ["shut", 1]
    ],
    "boing": [
      ["squash", 2, 0, 0, "dust_small"],
      ["spring", 1, 0, 1],
      ["air", 1, 0, 3],
      ["air", 2, 0, 5],
      ["air", 1, 0, 4],
      ["air", 1, 0, 2],
      ["squash", 2, 0, 0, "dust_small"],
      ["spring", 1],
      ["base", 2],
      ["shut", 1]
    ],
    "rustle": [
      ["attn", 3],
      ["sway_l", 2, 0, 0, "dew"],
      ["sway_r", 2],
      ["sway_l", 2],
      ["sway_r", 2],
      ["attn", 3],
      ["base", 2],
      ["shut", 1]
    ],
    "sunbathe": [
      ["look_up", 5],
      ["sun", 28, 0, 0, "glint"],
      ["sun", 14, 0, 0, "glint"],
      ["look_up", 3],
      ["base", 2],
      ["shut", 1]
    ],
    "doze": [
      ["half", 10],
      ["base", 4],
      ["half", 12],
      ["base", 2],
      ["doze", 12],
      ["sleep", 4]
    ],
    "sleep": [
      ["sleep", 26, 0, 0, "zzz"],
      ["sleep_b", 26]
    ],
    "wake": [
      ["squash", 1],
      ["surprised", 2, 0, 2, "bang_grey"],
      ["surprised", 3],
      ["look_l", 3],
      ["look_r", 3],
      ["sway_l", 2],
      ["sway_r", 2],
      ["base", 1],
      ["shut", 1]
    ],
    "work_enter": [
      ["squash", 2, 0, 0, "dust_small"],
      ["spring", 2, 0, 1],
      ["perk", 2],
      ["base", 1]
    ],
    "lap_open": [
      ["squash", 1, 0, 0, "dust_small"],
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
      ["lap_a", 2, 0, 0, "code"],
      ["lap_b", 2],
      ["lap_a", 2],
      ["lap_b", 2],
      ["lap_a", 2],
      ["lap_b", 2],
      ["lap_look", 8],
      ["lap_a", 2],
      ["lap_b", 2],
      ["lap_a", 2],
      ["lap_b", 2, 0, 0, "code"],
      ["lap_a", 2],
      ["lap_b", 2],
      ["lap_a", 2],
      ["lap_b", 2],
      ["lap_enter_up", 3],
      ["lap_a", 1, 0, 0, "code"],
      ["lap_happy", 5],
      ["lap_b", 2],
      ["lap_a", 2]
    ],
    "lap_close": [
      ["lap_look", 1],
      ["lap_half", 2],
      ["lap_closed", 2],
      ["squash", 1, 0, 0, "dust_small"],
      ["base", 1]
    ],
    "think": [
      ["think", 10],
      ["think_edge", 3],
      ["think", 3],
      ["think_edge", 2],
      ["think", 2, 0, 1],
      ["think_edge", 2, 0, 1],
      ["think", 2, 0, 1],
      ["think_edge", 2, 0, 1],
      ["think", 4],
      ["think_l", 10],
      ["think", 8]
    ],
    "read": [
      ["read_r", 8],
      ["read_r", 3, 1, 0],
      ["read_r", 3, 2, 0],
      ["read_r", 6, 2, 0],
      ["read_r", 3, 1, 0],
      ["look_down", 3],
      ["read_l", 8],
      ["read_l", 3, -1, 0],
      ["read_l", 3, -2, 0],
      ["read_l", 6, -2, 0],
      ["read_l", 3, -1, 0],
      ["look_down", 3]
    ],
    "bash": [
      ["jog_a", 2, 0, 1],
      ["jog_b", 2],
      ["jog_a", 2, 0, 1],
      ["jog_b", 2, 0, 0, "kick"],
      ["jog_a", 2, 0, 1],
      ["jog_b", 2],
      ["jog_a", 2, 0, 1],
      ["jog_b", 2, 0, 0, "kick"],
      ["jog_a", 2, 0, 1],
      ["jog_b", 2],
      ["jog_a", 2, 0, 1, "sweat"],
      ["jog_b", 2, 0, 0, "kick"],
      ["jog_a", 2, 0, 1],
      ["jog_b", 2],
      ["jog_a", 2, 0, 1],
      ["jog_b", 2, 0, 0, "kick"]
    ],
    "juggle": [
      ["juggle_a", 3],
      ["juggle_b", 3]
    ],
    "alert": [
      ["surprised", 2],
      ["squash", 1, 0, 0, "dust_small"],
      ["urgent", 1, 0, 2],
      ["urgent", 2, 0, 4],
      ["urgent", 1, 0, 3],
      ["air", 1, 0, 1],
      ["squash", 2, 0, 0, "dust"],
      ["raise", 2]
    ],
    "ask": [
      ["raise", 5],
      ["raise_mid", 3],
      ["raise", 5],
      ["raise_mid", 3],
      ["raise", 5],
      ["attn", 16],
      ["attn_shut", 1],
      ["attn", 10]
    ],
    "impatient": [
      ["attn_tap", 2],
      ["attn", 2],
      ["attn_tap", 2],
      ["attn", 2],
      ["attn_tap", 1],
      ["attn", 1],
      ["attn_tap", 1],
      ["attn", 1],
      ["attn_tap", 1],
      ["attn", 1],
      ["raise", 3],
      ["raise_mid", 2],
      ["raise", 3],
      ["raise_mid", 2],
      ["squash", 1, 0, 0, "dust"],
      ["urgent", 2, 0, 3],
      ["urgent", 1, 0, 1],
      ["attn", 6]
    ],
    "celebrate": [
      ["squash", 2, 0, 0, "dust"],
      ["cheer", 1, 0, 2],
      ["cheer", 2, 0, 5, "petals"],
      ["cheer", 1, 0, 4],
      ["cheer", 1, 0, 2],
      ["squash_happy", 2, 0, 0, "dust_small"],
      ["cheer", 1, 0, 2],
      ["cheer", 2, 0, 3],
      ["cheer", 1, 0, 2],
      ["squash_happy", 2],
      ["bloom", 10]
    ],
    "content": [
      ["bloom", 30],
      ["bloom_open", 24],
      ["bloom_shut", 1],
      ["bloom_open", 18],
      ["bloom_sl", 4],
      ["bloom_open", 2],
      ["bloom_sr", 4],
      ["bloom_open", 10],
      ["bloom", 12]
    ],
    "bloom_wink": [
      ["bloom_wink", 6],
      ["bloom_open", 1]
    ],
    "bloom_look": [
      ["bloom_l", 6],
      ["bloom_open", 2],
      ["bloom_r", 6],
      ["bloom_shut", 1]
    ],
    "bloom_sway": [
      ["bloom_sl", 4],
      ["bloom_sr", 4],
      ["bloom_sl", 4],
      ["bloom_open", 2]
    ],
    "seen": [
      ["bloom_open", 3],
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
      ["slump", 4, 0, 0, "sweat"],
      ["slump", 2, 0, -1, "shed_fall"]
    ],
    "slump": [
      ["slump", 36, 0, -1],
      ["slump_shut", 2, 0, -1],
      ["slump", 28, 0, -1],
      ["slump_shut", 4, 0, -1, "sigh"],
      ["slump", 12, 0, -1]
    ],
    "notice": [
      ["attn", 2, 0, 1],
      ["base", 1]
    ],
    "pet": [
      ["happy_l", 3, 0, 0, "heart"],
      ["happy_r", 3]
    ],
    "pet_end": [
      ["happy", 8],
      ["shut", 1]
    ],
    "press": [
      ["squeeze", 1, 0, 0, "dust"],
      ["squeeze", 200]
    ],
    "boop_end": [
      ["spring", 1, 0, 1],
      ["air", 1, 0, 2],
      ["squash", 1, 0, 0, "dust_small"],
      ["look_l", 4],
      ["base", 1],
      ["shut", 1]
    ],
    "held": [
      ["held_a", 2],
      ["held_b", 2]
    ],
    "drop": [
      ["air", 1, 0, 2],
      ["squash", 2, 0, 0, "dust"],
      ["spring", 1],
      ["look_l", 2],
      ["look_r", 2],
      ["base", 1],
      ["shut", 1]
    ],
    "emerge": [
      ["base", 4, 0, -10, "dirt"],
      ["sway_l", 3, 0, -10],
      ["sway_r", 3, 0, -10],
      ["base", 2, 0, -8],
      ["look_l", 4, 0, -5],
      ["look_r", 4, 0, -5],
      ["base", 2, 0, -5],
      ["spring", 1, 0, -2, "dirt"],
      ["air", 1, 0, 2],
      ["air", 2, 0, 3],
      ["air", 1, 0, 2],
      ["squash", 2, 0, 0, "dust_small"],
      ["base", 1],
      ["shut", 1],
      ["base", 2]
    ],
    "goodbye": [
      ["wave_hi", 3],
      ["wave_mid", 2],
      ["wave_hi", 3],
      ["wave_mid", 2],
      ["wave_hi", 3],
      ["base", 2],
      ["squash", 1, 0, 0, "dirt"],
      ["look_l", 3, 0, -5],
      ["look_r", 3, 0, -5],
      ["base", 2, 0, -8],
      ["sway_l", 2, 0, -10],
      ["sway_r", 2, 0, -10],
      ["base", 2, 0, -12, "dirt_poof"]
    ],
    "pop_up": [
      ["base", 3, 0, -12],
      ["base", 2, 0, -10, "dirt"],
      ["base", 1, 0, -6],
      ["spring", 1, 0, -2],
      ["air", 1, 0, 2, "dirt"],
      ["air", 2, 0, 4],
      ["air", 1, 0, 3],
      ["air", 1, 0, 1],
      ["squash", 2, 0, 0, "dust_small"],
      ["base", 1],
      ["shut", 1]
    ],
    "burrow": [
      ["squash", 1, 0, 0, "dust_small"],
      ["look_l", 2, 0, -4, "dirt"],
      ["base", 2, 0, -8],
      ["sway_r", 2, 0, -10],
      ["base", 2, 0, -12, "dirt_poof"]
    ]
  },
  "effects": {
    "dust": {
      "particles": [
        {
          "glyph": "dot",
          "color": "#B4BAC4",
          "x": 1,
          "y": 9,
          "vx": -12,
          "vy": -3,
          "life": 4
        },
        {
          "glyph": "dot",
          "color": "#B4BAC4",
          "x": 16,
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
          "x": 2,
          "y": 9,
          "vx": -8,
          "vy": -2,
          "life": 3
        },
        {
          "glyph": "dot",
          "color": "#B4BAC4",
          "x": 15,
          "y": 9,
          "vx": 8,
          "vy": -2,
          "life": 3
        }
      ]
    },
    "kick": {
      "particles": [
        {
          "glyph": "dot",
          "color": "#B4BAC4",
          "x": 3,
          "y": 9,
          "vx": -10,
          "vy": -4,
          "life": 4
        }
      ]
    },
    "puff": {
      "particles": [
        {
          "glyph": "tilde",
          "color": "#B4BAC4",
          "x": 16,
          "y": 4,
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
    "dew": {
      "particles": [
        {
          "count": 3,
          "glyph": "dot",
          "color": "#9FD8F5",
          "x": [5, 12],
          "y": -2,
          "vx": [-14, 14],
          "vy": [-12, -6],
          "ay": 70,
          "life": [6, 9]
        }
      ]
    },
    "glint": {
      "particles": [
        {
          "glyph": "spark",
          "color": "#FFE9A8",
          "x": 1,
          "y": -6,
          "life": 8,
          "shrinkTo": "dot"
        }
      ]
    },
    "petals": {
      "particles": [
        {
          "count": 14,
          "glyph": "dot",
          "colors": ["#FF8FB8", "#FFD24A", "#6BCB5F", "#B39DF3", "#FFFFFF", "#FF8FB8"],
          "x": [4, 13],
          "y": -2,
          "vx": [-18, 18],
          "vy": [-34, -16],
          "ay": 80,
          "life": [13, 19]
        },
        {
          "count": 2,
          "glyph": "shed",
          "color": "#6BCB5F",
          "x": [5, 12],
          "y": -2,
          "vx": [-10, 10],
          "vy": [-26, -18],
          "ay": 60,
          "sway": 1,
          "life": [16, 20]
        }
      ]
    },
    "zzz": {
      "cycle": [
        [
          {
            "glyph": "z",
            "color": "#A3A9B4",
            "x": 14,
            "y": -3,
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
            "x": 14,
            "y": -3,
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
          "y": -3,
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
            "y": 2,
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
            "y": 2,
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
            "y": 2,
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
          "y": -1,
          "vx": 0,
          "vy": 4,
          "life": 14
        }
      ]
    },
    "shed_fall": {
      "particles": [
        {
          "glyph": "shed",
          "color": "#6BCB5F",
          "x": 11,
          "y": -3,
          "vx": 3,
          "vy": 3,
          "sway": 1,
          "life": 24
        }
      ]
    },
    "dirt": {
      "particles": [
        {
          "count": 4,
          "glyph": "dot",
          "colors": ["#8A6A4F", "#A98462", "#6E533D"],
          "x": [5, 12],
          "y": 9,
          "vx": [-14, 14],
          "vy": [-20, -10],
          "ay": 70,
          "life": [5, 8]
        }
      ]
    },
    "dirt_poof": {
      "particles": [
        {
          "count": 6,
          "glyph": "dot",
          "colors": ["#8A6A4F", "#A98462", "#6E533D"],
          "x": [5, 12],
          "y": 9,
          "vx": [-16, 16],
          "vy": [-24, -12],
          "ay": 70,
          "life": [6, 9]
        },
        {
          "glyph": "shed",
          "color": "#6BCB5F",
          "x": 8,
          "y": 7,
          "vx": 2,
          "vy": -6,
          "sway": 1,
          "life": 12
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
    "sun": {
      "frames": ["sun0", "sun1", "sun2", "sun3", "sun4"],
      "color": "#F2B33D",
      "periodMs": 2000,
      "box": 7,
      "reduced": "sun3"
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
          ["stroll", 2],
          ["yawn", 1],
          ["boing", 1],
          ["rustle", 2],
          ["sunbathe", 1]
        ]
      },
      "sleep": {
        "after": 2000,
        "doze": "doze",
        "loop": "sleep",
        "wake": "wake",
        "still": "sleep"
      }
    },
    "running": {
      "enter": "work_enter",
      "accessory": "sun",
      "still": "lap_a",
      "defaultVariant": "laptop",
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
      "still": "bloom",
      "seen": "seen",
      "fidget": {
        "every": [90, 220],
        "pick": [
          ["bloom_wink", 1],
          ["bloom_look", 1],
          ["bloom_sway", 1]
        ]
      },
      "gaze": {
        "left": "bloom_l",
        "right": "bloom_r",
        "up": "bloom_up",
        "down": "bloom_down",
        "center": "bloom_open"
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
    "join": "emerge",
    "leave": "goodbye",
    "appear": "pop_up",
    "vanish": "burrow",
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
      "glyph": "seed",
      "colors": ["#6BCB5F", "#FF8FB8", "#FFD24A"]
    }
  }
}

"""#

    public static func builtin() -> SkinManifest {
        // `builtinJSON` is a fixed, valid literal covered by `builtinIsValidSchema2` and
        // `builtinIsTheBundledSprig`, so decoding it can never fail in practice.
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
