import CoreGraphics
import CritterClient
import CritterKit
import Foundation
import UIKit

/// The Live Activity's pictures (spec §8.5): still Critters drawn by the shared engine (`MotionActor`, `SpriteDrawing`),
/// at the pixels they are shown at, and nothing kept once drawn. The widget extension has little memory and each new
/// content draws them again: a pile on the lock screen is 270 × 207 pixels, a lone Critter in the Dynamic Island a
/// fifth of that.
///
/// Also compiled into the app (DEBUG's `-critterActivityDemo` shows the lock screen's look in the app, which the
/// simulator cannot lock).
enum ActivityPictures {
    /// The pile is this many cells wide and tall: the mockups' collapsed floating ball (visual design §8.4).
    static let pileColumns = 30
    static let pileRows = 23
    /// A lone Critter is this many cells square, standing on the bottom edge (as the app's `Portraits`).
    static let loneCells = 20

    /// The lead stands this many cells from the left, its base box centred; the ground is one cell up, the row under it
    /// the pile's shadow.
    private static let leadColumn = 6
    /// The two behind the lead: this many cells to its left and to its right, raised three rows onto the back of the pile,
    /// dimmed, at 80 %, without head marks (the mockups' pile).
    private static let backOffsets = [-5, 5]
    private static let backRaise = 3
    private static let backAlpha = 0.8

    /// The collapsed pile: `lead` in front in its state's representative pose, `back` behind it raised and dimmed, a
    /// shadow under them. No lead (no sessions): one sprig, asleep and dimmed. `cellPixels` pixels a cell, shown at
    /// `scale` pixels a point; `dimLead` dims the lead as well (the board's rule for idle and done Critters); `grey`
    /// draws it all in grey (stale).
    static func pile(
        lead: PetBadge?, back: [PetBadge], cellPixels: Int, scale: CGFloat, dimLead: Bool = false, grey: Bool = false
    ) -> UIImage? {
        let u = max(1, cellPixels)
        let width = pileColumns * u, height = pileRows * u
        guard let context = bitmap(width: width, height: height) else { return nil }
        let library = ActivitySkins.library(for: [lead?.skin, back.first?.skin, back.dropFirst().first?.skin].compactMap { $0 })
        let unit = CGFloat(u)
        // The pile's shadow, two rows under the feet (the mockups' `under`): ink at 16 %, y up.
        context.setFillColor(CGColor(srgbRed: 20 / 255, green: 10 / 255, blue: 40 / 255, alpha: 0.16))
        context.fill(CGRect(x: 4 * unit, y: 0, width: 22 * unit, height: unit))
        context.fill(CGRect(x: 7 * unit, y: unit - max(1, (unit / 3).rounded()), width: 16 * unit, height: unit))

        for (badge, offset) in zip(back.prefix(backOffsets.count), backOffsets) {
            let skin = library.manifest(badge.skin)
            let actor = seated(skin: skin, state: badge.state)
            SpriteDrawing.draw(
                actor.snapshot(), atlas: SpriteAtlas(skin: skin, dimStrength: 1), unit: unit, seatRow: backRaise,
                ground: CGPoint(x: CGFloat(leadColumn + offset) * unit, y: unit), in: context
            )
        }
        let skin = library.manifest(lead?.skin ?? PhoneSkinLibrary.fallback)
        let actor = still(skin: skin, state: lead?.state, dim: dimLead)
        SpriteDrawing.draw(
            actor.snapshot(), atlas: SpriteAtlas(skin: skin, dimStrength: 1), unit: unit,
            ground: CGPoint(x: CGFloat(leadColumn) * unit, y: unit), in: context
        )
        if grey { greyOut(context) }
        return context.makeImage().map { UIImage(cgImage: $0, scale: scale, orientation: .up) }
    }

    /// One Critter alone, `loneCells` square: the base box from the second column, on the bottom row, in its state's
    /// representative pose with its head mark. No badge: a sleeping sprig.
    static func lone(_ badge: PetBadge?, cellPixels: Int, scale: CGFloat, dim: Bool = false, grey: Bool = false) -> UIImage? {
        let u = max(1, cellPixels)
        let side = loneCells * u
        guard let context = bitmap(width: side, height: side) else { return nil }
        let skin = ActivitySkins.library(for: badge.map { [$0.skin] } ?? []).manifest(badge?.skin ?? PhoneSkinLibrary.fallback)
        let actor = still(skin: skin, state: badge?.state, dim: dim)
        SpriteDrawing.draw(
            actor.snapshot(), atlas: SpriteAtlas(skin: skin, dimStrength: 1), unit: CGFloat(u),
            ground: CGPoint(x: CGFloat(u), y: 0), in: context
        )
        if grey { greyOut(context) }
        return context.makeImage().map { UIImage(cgImage: $0, scale: scale, orientation: .up) }
    }

    /// The lightness of a colour (each part 0...1), as a grey stands in for it: Rec. 601's weights.
    static func luma(_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.299 * r + 0.587 * g + 0.114 * b
    }

    /// The pixels a cell takes to be `points` wide at `scale`: whole pixels, so the art stays crisp.
    static func cellPixels(points: CGFloat, scale: CGFloat) -> Int {
        max(1, Int((points * scale).rounded()))
    }

    // MARK: -

    /// A Critter standing still in `state`'s representative pose (what reduce motion shows), with its head mark; no
    /// state: asleep and dimmed (the empty pile).
    private static func still(skin: SkinManifest, state: PetState?, dim: Bool) -> MotionActor {
        let actor = MotionActor(skin: skin, rng: MotionRNG(seed: 1), reduceMotion: true)
        actor.enterState(state ?? .idle, quiet: true)
        if state == nil {
            actor.sleepNow()
            actor.tint = .dim
        } else if dim {
            actor.tint = .dim
        }
        return actor
    }

    /// A Critter on the back of the pile: landed `backRaise` rows up, dimmed, without marks. (Reduce motion would
    /// stand it on the ground in its state's pose, so it keeps the motion and its loop is that one key.)
    private static func seated(skin: SkinManifest, state: PetState) -> MotionActor {
        let actor = MotionActor(skin: skin, rng: MotionRNG(seed: 1), reduceMotion: false)
        actor.enterState(state, quiet: true)
        actor.cancelOnce()
        actor.brainEnabled = false
        actor.noAccessory = true
        actor.setMode(nil)
        actor.setLoop(clip: [ClipKey(pose: skin.interactions.land, ticks: 9999, dx: 0, dy: backRaise)], name: nil)
        actor.tint = .dim
        actor.alpha = backAlpha
        return actor
    }

    /// Every pixel of `context` (8-bit RGBA, premultiplied) replaced by the grey of its lightness.
    private static func greyOut(_ context: CGContext) {
        guard let data = context.data else { return }
        let pixels = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * context.height)
        for y in 0..<context.height {
            let row = pixels + y * context.bytesPerRow
            for x in 0..<context.width {
                let p = row + 4 * x
                let grey = UInt8(min(255, luma(Double(p[0]), Double(p[1]), Double(p[2])).rounded()))
                p[0] = grey
                p[1] = grey
                p[2] = grey
            }
        }
    }

    /// A clear bitmap, y up like the sprite layers (the ground is the bottom edge).
    private static func bitmap(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}

/// Where the Live Activity finds a skin by name (`PhoneSkinLibrary`'s rules): one the Mac sent, which the app keeps in
/// the App Group's `Skins/<name>.json`, wins; then the one bundled with this target (`Skins/<name>/manifest.json`);
/// anything else is sprig. Only the names asked for are read.
enum ActivitySkins {
    static func library(for names: [String]) -> PhoneSkinLibrary {
        var pushed: [String: Data] = [:]
        for name in Set(names) where PhoneSkinLibrary.isPlain(name) {
            let file = SharedContainer.skinsFolder.appending(path: "\(name).json")
            if let data = try? Data(contentsOf: file) { pushed[name] = data }
        }
        return PhoneSkinLibrary(bundled: bundled, pushed: pushed, forced: nil, clockSkin: nil, reuse: nil)
    }

    private static func bundled(_ name: String) -> SkinManifest? {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "Skins/\(name)"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return SkinLoader.decode(data)
    }
}
