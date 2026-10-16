import Foundation

/// A complete, data-driven description of how the pet looks and animates: no animation is
/// hardcoded in Swift, so a brand-replacement skin only has to supply a valid manifest.
public struct SkinManifest: Codable, Sendable, Equatable {
    public var schema: Int
    public var name: String
    public var pixelAspect: [Int]
    public var palette: [String: String]
    public var frames: [String: [String]]
    public var animations: [String: AnimationSpec]

    public init(
        schema: Int,
        name: String,
        pixelAspect: [Int],
        palette: [String: String],
        frames: [String: [String]],
        animations: [String: AnimationSpec]
    ) {
        self.schema = schema
        self.name = name
        self.pixelAspect = pixelAspect
        self.palette = palette
        self.frames = frames
        self.animations = animations
    }
}

/// How a state's animation moves as a whole, layered on top of its frame flipbook.
public enum Motion: String, Codable, Sendable {
    case none, hop, wiggle, breathe
}

/// A color post-processing effect applied to a whole animation's frames.
public enum Tint: String, Codable, Sendable {
    case dim
}

/// The small text badge shown above the pet for a given state (e.g. "z z" for idle).
public struct Accessory: Codable, Equatable, Sendable {
    public var text: String
    public var color: String

    public init(text: String, color: String) {
        self.text = text
        self.color = color
    }
}

/// One state's full animation: which frames to flip through, how fast, and any motion/tint/
/// accessory layered on top.
public struct AnimationSpec: Codable, Sendable, Equatable {
    public var frames: [String]
    public var fps: Double
    public var motion: Motion
    public var tint: Tint?
    public var accessory: Accessory?

    public init(frames: [String], fps: Double, motion: Motion, tint: Tint? = nil, accessory: Accessory? = nil) {
        self.frames = frames
        self.fps = fps
        self.motion = motion
        self.tint = tint
        self.accessory = accessory
    }
}

/// Checks a manifest is internally consistent and complete enough to render, so a broken or
/// partial custom skin can be safely rejected (falling back to the builtin) instead of
/// crashing or rendering garbage.
public enum SkinValidator {
    public static func problems(_ m: SkinManifest) -> [String] {
        var problems: [String] = []

        let allRows = m.frames.values.flatMap { $0 }
        if let width = allRows.first?.count, allRows.contains(where: { $0.count != width }) {
            problems.append("frame rows have inconsistent width")
        }
        if let rowCount = m.frames.values.first?.count, m.frames.values.contains(where: { $0.count != rowCount }) {
            problems.append("frames have inconsistent row count")
        }

        let paletteChars = Set(m.palette.keys.compactMap(\.first))
        for (name, rows) in m.frames {
            for row in rows {
                for ch in row where ch != "." && !paletteChars.contains(ch) {
                    problems.append("frame \(name) uses character '\(ch)' not in the palette")
                }
            }
        }

        for (animName, spec) in m.animations {
            for frameName in spec.frames where m.frames[frameName] == nil {
                problems.append("animation \(animName) references missing frame \(frameName)")
            }
            if spec.fps <= 0 {
                problems.append("animation \(animName) has non-positive fps")
            }
        }

        for state in PetState.allCases where m.animations[state.rawValue] == nil {
            problems.append("missing animation for state \(state.rawValue)")
        }

        return problems
    }
}

/// Loads skin manifests: the builtin (always valid, embedded in the binary) and any
/// on-disk skin found by searching a list of directories in order.
public enum SkinLoader {
    /// The exact text of `Skins/clawd/manifest.json`, embedded so the builtin skin never
    /// depends on any file being present at runtime.
    public static let builtinJSON: String = """
{
  "schema": 1,
  "name": "clawd",
  "pixelAspect": [1, 2],
  "palette": {
    "#": "#D97757",
    "o": "#1D1D1F"
  },
  "frames": {
    "base": [
      "...############...",
      "...##o######o##...",
      ".################.",
      "...############...",
      "....#.#....#.#...."
    ],
    "blink": [
      "...############...",
      "...############...",
      ".################.",
      "...############...",
      "....#.#....#.#...."
    ],
    "step": [
      "...############...",
      "...##o######o##...",
      ".################.",
      "...############...",
      "...#.#......#.#..."
    ]
  },
  "animations": {
    "idle": {
      "frames": ["base", "base", "base", "base", "blink"],
      "fps": 2,
      "motion": "none",
      "tint": "dim",
      "accessory": { "text": "z z", "color": "#8E8E93" }
    },
    "running": {
      "frames": ["base", "step"],
      "fps": 4,
      "motion": "hop",
      "accessory": { "text": "•••", "color": "#8E8E93" }
    },
    "waiting": {
      "frames": ["base"],
      "fps": 2,
      "motion": "wiggle",
      "accessory": { "text": "?", "color": "#FF9F0A" }
    },
    "done": {
      "frames": ["base", "blink", "base", "base"],
      "fps": 2,
      "motion": "breathe",
      "accessory": { "text": "✓", "color": "#34C759" }
    },
    "error": {
      "frames": ["base"],
      "fps": 1,
      "motion": "none",
      "tint": "dim",
      "accessory": { "text": "!", "color": "#FF3B30" }
    }
  }
}
"""

    public static func builtin() -> SkinManifest {
        // `builtinJSON` is a fixed, valid literal covered by `builtinMatchesSpecGrid` and
        // `bundledFileEqualsBuiltin`, so decoding it can never fail in practice.
        try! JSONDecoder().decode(SkinManifest.self, from: Data(builtinJSON.utf8))
    }

    /// Searches `searchDirs` in order for `<dir>/<name>/manifest.json`; the first one that
    /// both decodes and passes `SkinValidator.problems` wins. Falls back to `builtin()` if
    /// none qualifies.
    public static func load(name: String, searchDirs: [URL]) -> SkinManifest {
        for dir in searchDirs {
            let manifestURL = dir.appendingPathComponent(name).appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(SkinManifest.self, from: data),
                  SkinValidator.problems(manifest).isEmpty
            else {
                continue
            }
            return manifest
        }
        return builtin()
    }
}
