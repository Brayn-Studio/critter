import CoreGraphics
import QuartzCore
import Testing
@testable import CritterKit

private let skin = SkinLoader.builtin()

private func actor() -> MotionActor {
    MotionActor(skin: skin, rng: MotionRNG(seed: 3), reduceMotion: false)
}

private func near(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9
        && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
}

/// Renders `s` into a sprite layer at the ground origin (0, 0) and checks that every visible sublayer sits where
/// `SpriteDrawing` draws, and that nothing else is shown.
private func expectLayerMatchesDrawing(_ s: ActorSnapshot, unit: CGFloat, seatRow: Int? = nil, _ label: String) {
    let atlas = SpriteAtlas(skin: skin, dimStrength: 1)
    let layer = CritterSpriteLayer(atlas: atlas, unit: unit)
    layer.seatRow = seatRow
    layer.render(s)
    guard let layout = SpriteLayout(s, atlas: atlas, unit: unit, seatRow: seatRow) else {
        #expect(layer.isHidden, "\(label): hidden")
        return
    }
    let steps = SpriteDrawing.steps(layout, ground: .zero)
    #expect(!layer.isHidden, "\(label)")

    let shadow = steps.compactMap { if case .shadow(let r) = $0 { r } else { nil } }.first
    #expect(layer.shadowLayer.isHidden == (shadow == nil), "\(label): shadow shown")
    if let shadow {
        #expect(near(layer.shadowLayer.frame, shadow), "\(label): shadow \(layer.shadowLayer.frame) vs \(shadow)")
    }

    let body = steps.compactMap { if case .body(let r, let clip, let a) = $0 { (r, clip, a) } else { nil } }.first
    #expect(layer.bodyLayer.isHidden == (body == nil), "\(label): body shown")
    if let (rect, clip, alpha) = body {
        #expect(near(layer.clipLayer.frame, clip), "\(label): clip")
        let drawn = layer.bodyLayer.frame.offsetBy(dx: layer.clipLayer.frame.minX, dy: layer.clipLayer.frame.minY)
        #expect(near(drawn, rect), "\(label): body \(drawn) vs \(rect)")
        #expect(Double(layer.bodyLayer.opacity) == Double(Float(alpha)), "\(label): body alpha")
    }

    var drawnGlyphs: Set<Int> = []
    for step in steps {
        guard case .glyph(let index, let rect, let alpha) = step else { continue }
        drawnGlyphs.insert(index)
        let glyph = layer.glyphLayers[index]
        #expect(!glyph.isHidden, "\(label): glyph \(index) shown")
        #expect(near(glyph.frame, rect), "\(label): glyph \(index) \(glyph.frame) vs \(rect)")
        #expect(Double(glyph.opacity) == Double(Float(alpha)), "\(label): glyph \(index) alpha")
    }
    for (index, glyph) in layer.glyphLayers.enumerated() where !drawnGlyphs.contains(index) {
        #expect(glyph.isHidden, "\(label): glyph \(index) hidden")
    }
}

@Test func spriteLayerAndDrawingAgreeStandingOnTheGround() {
    let a = actor()
    a.enterState(.idle, quiet: true)
    let s = a.snapshot()
    #expect(s.shadowWidth == 0)
    expectLayerMatchesDrawing(s, unit: 3, "standing")
    expectLayerMatchesDrawing(s, unit: 2.5, "standing, fractional unit")
}

@Test func spriteLayerAndDrawingAgreeLiftedAndCarried() {
    let a = actor()
    a.enterState(.idle, quiet: true)
    a.setMode(a.skin.interactions.held)
    a.lift = 3
    a.carry(dxCells: 7)
    let s = a.snapshot()
    #expect(s.shadowWidth > 0, "a lifted Critter casts a shadow")
    #expect(s.offsetX == 7)
    expectLayerMatchesDrawing(s, unit: 4, "held")
}

@Test func spriteLayerAndDrawingAgreeWithAHeadMarkerAndABadge() {
    let a = actor()
    a.enterState(.waiting)
    var s = a.snapshot()
    for _ in 0..<40 where s.accessory == nil || s.badge == nil {
        a.step()
        s = a.snapshot()
    }
    #expect(s.accessory != nil, "the waiting mark")
    expectLayerMatchesDrawing(s, unit: 3, "waiting")
    a.enterState(.running, quiet: true)
    expectLayerMatchesDrawing(a.snapshot(), unit: 6, "running")
}

@Test func spriteLayerAndDrawingAgreeWithParticles() {
    let a = actor()
    a.enterState(.idle, quiet: true)
    a.sleepNow()
    var s = a.snapshot()
    for _ in 0..<60 where s.particles.isEmpty {
        a.step()
        s = a.snapshot()
    }
    #expect(!s.particles.isEmpty, "the snoring z")
    expectLayerMatchesDrawing(s, unit: 2, "asleep")
}

@Test func spriteLayerAndDrawingAgreeSeatedInAPile() {
    let a = actor()
    a.enterState(.idle, quiet: true)
    a.brainEnabled = false
    a.travel(fromDx: 0, fromDy: 0, delay: 0, seat: PileSeating.seat(row: 1))
    for _ in 0..<40 { a.step() }
    let s = a.snapshot()
    expectLayerMatchesDrawing(s, unit: 3, seatRow: 1, "seated")
    #expect(SpriteLayout(s, atlas: SpriteAtlas(skin: skin, dimStrength: 1), unit: 3, seatRow: 1)?.shadow == nil)
}

@Test func aHiddenCritterHasNoLayout() {
    let a = actor()
    a.hidden = true
    #expect(SpriteLayout(a.snapshot(), atlas: SpriteAtlas(skin: skin, dimStrength: 1), unit: 3) == nil)
}

@Test func drawingPutsThePiecesWhereTheStepsSay() throws {
    // A bitmap drawn by SpriteDrawing has the body's pixels inside the body step's rectangle (y up, like the layer).
    let a = actor()
    a.enterState(.idle, quiet: true)
    let atlas = SpriteAtlas(skin: skin, dimStrength: 1)
    let s = a.snapshot()
    let unit: CGFloat = 2
    let ground = CGPoint(x: 2, y: 0)
    let context = try #require(CGContext(
        data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    SpriteDrawing.draw(s, atlas: atlas, unit: unit, ground: ground, in: context)
    let layout = try #require(SpriteLayout(s, atlas: atlas, unit: unit))
    guard case .body(let rect, _, _)? = SpriteDrawing.steps(layout, ground: ground).first(where: {
        if case .body = $0 { true } else { false }
    }) else {
        Issue.record("no body step")
        return
    }
    let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = context.bytesPerRow
    var painted = CGRect.null
    for row in 0..<40 {
        for x in 0..<40 where data[row * bytesPerRow + x * 4 + 3] > 0 {
            // Memory row 0 is the top of the picture: y up = 39 - row.
            painted = painted.union(CGRect(x: x, y: 39 - row, width: 1, height: 1))
        }
    }
    #expect(!painted.isNull)
    #expect(rect.contains(painted), "painted \(painted) inside the body step \(rect)")
}

/// The layer's formulas before `SpriteLayout` (CritterSpriteLayer at 6dc65bd), written out: the refactor must place
/// every sublayer exactly where they did, so the Mac's flock does not move by a point.
@Test func spriteLayerPlacesEverythingAsBefore() {
    let a = actor()
    a.enterState(.waiting)
    for _ in 0..<12 { a.step() }
    a.setMode(a.skin.interactions.held)
    a.lift = 3
    a.carry(dxCells: -4)
    let s = a.snapshot()
    let u: CGFloat = 3
    let atlas = SpriteAtlas(skin: skin, dimStrength: 1)
    let layer = CritterSpriteLayer(atlas: atlas, unit: u)
    layer.render(s)

    let bx = CGFloat(s.offsetX) * u, by = CGFloat(s.offsetY) * u, bodyX = CGFloat(s.bodyX)
    #expect(layer.clipLayer.frame == CGRect(x: bx + (bodyX - 12) * u, y: by, width: (18 + 24) * u, height: 40 * u))
    if let pose = atlas.pose(s.pose, dim: s.tint == .dim) {
        let grid = pose.grid
        #expect(layer.bodyLayer.frame == CGRect(
            x: (CGFloat(grid.minX) + 12) * u,
            y: (10 - CGFloat(grid.minY) - CGFloat(grid.height) + CGFloat(s.bodyY)) * u,
            width: CGFloat(grid.width) * u, height: CGFloat(grid.height) * u
        ))
    }
    #expect(s.shadowWidth > 0)
    let width = CGFloat(s.shadowWidth)
    let height = max(2, u / 2)
    #expect(layer.shadowLayer.frame == CGRect(
        x: bx + (bodyX + 9 - width / 2) * u, y: by - height, width: width * u, height: height
    ))
    var draws = s.props + s.particles
    if let accessory = s.accessory { draws.append(accessory) }
    if let badge = s.badge { draws.append(badge) }
    for (index, d) in draws.enumerated() where atlas.glyph(d.glyph, color: d.color) != nil {
        let size = atlas.glyphSize(d.glyph)
        #expect(layer.glyphLayers[index].frame == CGRect(
            x: bx + CGFloat(d.x) * u, y: by + (10 - CGFloat(d.y) - CGFloat(size.height)) * u,
            width: CGFloat(size.width) * u, height: CGFloat(size.height) * u
        ))
    }
}
