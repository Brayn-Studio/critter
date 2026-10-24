import CritterKit
import SwiftUI
import UIKit

/// Still pictures of a Critter in its state's representative pose (what reduce motion shows; Android `Portraits`),
/// for the places where pets don't move: list tiles, the pro board, notifications. 20 × 20 cells: the base box starts
/// at column 1 and stands on the bottom row. Drawn once per look, at the screen's pixels (`scale` points a cell), and
/// kept in a small cache, most recently used last.
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
        var dimStrength: Double?
    }

    private static var cache: [Key: (manifest: SkinManifest, image: UIImage)] = [:]
    private static var recent: [Key] = []

    /// `skin` in `state`'s still pose, `scale` points a cell at `displayScale` pixels a point; dimmed like an idle
    /// Critter on the Mac (`dimStrength`, quantized like the atlases) with `dim`. Nil if the pose cannot be drawn.
    static func image(
        skin: SkinManifest, state: PetState, dim: Bool = false, scale: CGFloat, activity: String? = nil,
        asleep: Bool = false, dimStrength: Double = 0.5, displayScale: CGFloat = 3
    ) -> UIImage? {
        let u = max(1, Int((scale * displayScale).rounded()))
        let strength = dim ? AtlasPool.quantize(dimStrength) : nil
        let key = Key(
            skin: skin.name, state: state, activity: activity, cellPixels: u, displayScale: displayScale,
            asleep: asleep, dimStrength: strength
        )
        if let hit = cache[key], hit.manifest == skin {
            touch(key)
            return hit.image
        }
        let actor = MotionActor(skin: skin, rng: MotionRNG(seed: 1), reduceMotion: true)
        actor.setActivity(activity)
        actor.enterState(state, quiet: true)
        if asleep { actor.sleepNow() }
        actor.tint = dim ? .dim : nil

        let side = cells * u
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let atlas = AtlasPool.atlas(skin, dimStrength: strength ?? 0)
        // A bitmap context is y-up like the sprite layers: the ground is the bottom edge.
        CritterDrawing.draw(actor.snapshot(), atlas: atlas, in: context, ground: CGPoint(x: u, y: 0), unit: CGFloat(u))
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

/// `Portraits.image` as a view, `cell` points a cell (20 cells square), scaled without smoothing.
struct CritterPortrait: View {
    let manifest: SkinManifest
    let state: PetState
    let cell: CGFloat
    var activity: String?
    var asleep = false
    var dim = false
    var dimStrength = 0.5

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

/// One `ActorSnapshot` drawn into a Core Graphics context, exactly as `CritterSpriteLayer` lays it out (y up, `ground`
/// where the base box's column 0 meets the ground, `unit` a cell): the shadow, the body clipped at the ground, then
/// props, particles, the head marker and the badge.
enum CritterDrawing {
    private static let clipHeightCells: CGFloat = 40
    private static let clipMarginCells: CGFloat = 12
    private static let baseColumns: CGFloat = 18
    private static let groundRow: CGFloat = 10
    private static let shadowOpacity: CGFloat = 0.28

    static func draw(
        _ s: ActorSnapshot, atlas: SpriteAtlas, in context: CGContext, ground: CGPoint, unit u: CGFloat
    ) {
        guard !s.hidden else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        let bx = ground.x + CGFloat(s.offsetX) * u
        let by = ground.y + CGFloat(s.offsetY) * u
        let bodyX = CGFloat(s.bodyX)

        if s.shadowWidth > 0 {
            let width = CGFloat(s.shadowWidth)
            let height = max(2, u / 2)
            context.setFillColor(CGColor(gray: 0, alpha: shadowOpacity))
            context.fill(CGRect(x: bx + (bodyX + 9 - width / 2) * u, y: by - height, width: width * u, height: height))
        }

        if let pose = atlas.pose(s.pose, dim: s.tint == .dim) {
            let grid = pose.grid
            context.saveGState()
            context.clip(to: CGRect(
                x: bx + (bodyX - clipMarginCells) * u, y: by,
                width: (baseColumns + 2 * clipMarginCells) * u, height: clipHeightCells * u
            ))
            context.setAlpha(CGFloat(s.alpha))
            context.draw(pose.image, in: CGRect(
                x: bx + (bodyX + CGFloat(grid.minX)) * u,
                y: by + (groundRow - CGFloat(grid.minY) - CGFloat(grid.height) + CGFloat(s.bodyY)) * u,
                width: CGFloat(grid.width) * u, height: CGFloat(grid.height) * u
            ))
            context.restoreGState()
        }

        var draws = s.props + s.particles
        if let accessory = s.accessory { draws.append(accessory) }
        if let badge = s.badge { draws.append(badge) }
        for d in draws {
            guard let image = atlas.glyph(d.glyph, color: d.color) else { continue }
            let size = atlas.glyphSize(d.glyph)
            context.saveGState()
            context.setAlpha(CGFloat(d.alpha))
            context.draw(image, in: CGRect(
                x: bx + CGFloat(d.x) * u, y: by + (groundRow - CGFloat(d.y) - CGFloat(size.height)) * u,
                width: CGFloat(size.width) * u, height: CGFloat(size.height) * u
            ))
            context.restoreGState()
        }
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
