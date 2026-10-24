import CritterKit
import SwiftUI
import UIKit

/// Still pictures of a Critter in its state's representative pose (what reduce motion shows; Android `Portraits`),
/// for the places where pets don't move: list tiles, the pro board, notifications. 20 × 20 cells: the base box starts
/// at column 1 and stands on the bottom row. Drawn once per look by `SpriteDrawing` (laid out like the live sprite
/// layers), at the screen's pixels (`scale` points a cell), and kept in a small cache, most recently used last.
///
/// Dimming follows the live stage's rule, as the mockups' still pictures do: the engine tints a state that is dimmed
/// (`idle` and `error` in the bundled skins) and `dimStrength` (the Mac's `idleDim`, every slot's) says how much.
@MainActor
enum Portraits {
    /// The picture is this many cells wide and tall.
    static let cells = 20
    private static let capacity = 48

    private struct Key: Hashable {
        var skin: String
        var state: PetState
        var activity: String?
        var cellPixels: Int
        var displayScale: CGFloat
        var asleep: Bool
        var dim: Bool?
        var dimStrength: Double
    }

    private static var cache: [Key: (manifest: SkinManifest, image: UIImage)] = [:]
    private static var recent: [Key] = []

    /// `skin` in `state`'s still pose, `scale` points a cell at `displayScale` pixels a point. Dimmed as the stage
    /// dims it (the state's tint, at `dimStrength`, quantized like the atlases); `dim` overrides the state's tint:
    /// true dims every state (the pro board dims all but waiting), false none. Nil if the pose cannot be drawn.
    static func image(
        skin: SkinManifest, state: PetState, dim: Bool? = nil, scale: CGFloat, activity: String? = nil,
        asleep: Bool = false, dimStrength: Double = 1, displayScale: CGFloat = 3
    ) -> UIImage? {
        let u = max(1, Int((scale * displayScale).rounded()))
        let strength = AtlasPool.quantize(dimStrength)
        let key = Key(
            skin: skin.name, state: state, activity: activity, cellPixels: u, displayScale: displayScale,
            asleep: asleep, dim: dim, dimStrength: strength
        )
        if let hit = cache[key], hit.manifest == skin {
            touch(key)
            return hit.image
        }
        let actor = MotionActor(skin: skin, rng: MotionRNG(seed: 1), reduceMotion: true)
        actor.setActivity(activity)
        actor.enterState(state, quiet: true)
        if asleep { actor.sleepNow() }
        if let dim { actor.tint = dim ? .dim : nil }

        let side = cells * u
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let atlas = AtlasPool.atlas(skin, dimStrength: strength)
        // A bitmap context is y-up like the sprite layers: the ground is the bottom edge.
        SpriteDrawing.draw(
            actor.snapshot(), atlas: atlas, unit: CGFloat(u), ground: CGPoint(x: u, y: 0), in: context
        )
        guard let picture = context.makeImage() else { return nil }
        let image = UIImage(cgImage: picture, scale: displayScale, orientation: .up)
        cache[key] = (skin, image)
        touch(key)
        if recent.count > capacity {
            cache[recent.removeFirst()] = nil
        }
        return image
    }

    private static func touch(_ key: Key) {
        recent.removeAll { $0 == key }
        recent.append(key)
    }
}

/// `Portraits.image` as a view, `cell` points a cell (20 cells square), scaled without smoothing. Pass the stage's
/// `dimStrength` (`SkinStore.idleDim`) so the picture is dimmed as the live Critter would be.
struct CritterPortrait: View {
    let manifest: SkinManifest
    let state: PetState
    let cell: CGFloat
    var activity: String?
    var asleep = false
    var dim: Bool?
    var dimStrength = 1.0

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let side = CGFloat(Portraits.cells) * cell
        Group {
            if let image = Portraits.image(
                skin: manifest, state: state, dim: dim, scale: cell, activity: activity, asleep: asleep,
                dimStrength: dimStrength, displayScale: displayScale
            ) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
            } else {
                Color.clear
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// Atlases shared by every stage and the portraits (the same skins are drawn in many places), keyed by skin name and
/// dimming strength (Android `AtlasPool`).
@MainActor
enum AtlasPool {
    private static var atlases: [String: SpriteAtlas] = [:]

    /// The dimming strength in steps of 0.05, so a slider drag does not leave an atlas behind for every value.
    nonisolated static func quantize(_ strength: Double) -> Double {
        (min(max(strength, 0), 1) * 20).rounded() / 20
    }

    static func atlas(_ skin: SkinManifest, dimStrength: Double) -> SpriteAtlas {
        let strength = quantize(dimStrength)
        let key = "\(skin.name)@\(strength)"
        if let found = atlases[key], found.skin == skin { return found }
        let atlas = SpriteAtlas(skin: skin, dimStrength: strength)
        atlases[key] = atlas
        return atlas
    }
}
