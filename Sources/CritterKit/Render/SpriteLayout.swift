import CoreGraphics

/// Where one Critter's pieces go for an `ActorSnapshot`, in points, y up, relative to the ground origin (the point
/// where the base box's column 0 meets the ground), `unit` points a cell. The one place this is worked out:
/// `CritterSpriteLayer` places its sublayers by it and `SpriteDrawing` draws it into a Core Graphics context (the
/// phone's still portraits), so a still picture and a live Critter are laid out alike.
///
/// - the shadow just below the ground, centred under the body (none on the ground, none once seated in a pile);
/// - the body, clipped to `bodyClip` so a sinking pose disappears into the ground, the clip travelling with the key's
///   dx;
/// - the glyphs, bottom to top: props, particles, the head marker, the badge. Never clipped.
public struct SpriteLayout {
    /// An image and where it goes, drawn at `alpha`.
    public struct Piece {
        public var image: CGImage
        public var frame: CGRect
        public var alpha: Double
    }

    /// The body clip reaches this far above the ground...
    static let clipHeightCells: CGFloat = 40
    /// ...and this far to either side of the 18-cell base box.
    static let clipMarginCells: CGFloat = 12
    static let baseColumns: CGFloat = 18
    static let groundRow: CGFloat = 10
    public static let shadowOpacity: Float = 0.28

    /// The shadow's rectangle (black at `shadowOpacity`), nil when there is none.
    public var shadow: CGRect?
    /// The body is drawn inside this rectangle only.
    public var bodyClip: CGRect
    /// The body, nil for an unknown or empty pose.
    public var body: Piece?
    /// `body`'s frame relative to `bodyClip`'s origin (how the layer, whose body sits inside a clipping layer,
    /// places it).
    public var bodyFrameInClip: CGRect?
    /// Props, particles, the head marker and the badge in drawing order; nil for a glyph the skin does not have.
    public var glyphs: [Piece?]

    /// The layout of `s`, nil when it is hidden. `seatRow`: the pile row the Critter sits in (or hops to); once it
    /// sits there it casts no shadow, exactly like the still pile it turns into.
    public init?(_ s: ActorSnapshot, atlas: SpriteAtlas, unit u: CGFloat, seatRow: Int? = nil) {
        guard !s.hidden else { return nil }
        let bx = CGFloat(s.offsetX) * u
        let by = CGFloat(s.offsetY) * u
        let bodyX = CGFloat(s.bodyX)

        bodyClip = CGRect(
            x: bx + (bodyX - Self.clipMarginCells) * u, y: by,
            width: (Self.baseColumns + 2 * Self.clipMarginCells) * u, height: Self.clipHeightCells * u
        )
        if let pose = atlas.pose(s.pose, dim: s.tint == .dim) {
            let grid = pose.grid
            let inClip = CGRect(
                x: (CGFloat(grid.minX) + Self.clipMarginCells) * u,
                y: (Self.groundRow - CGFloat(grid.minY) - CGFloat(grid.height) + CGFloat(s.bodyY)) * u,
                width: CGFloat(grid.width) * u, height: CGFloat(grid.height) * u
            )
            bodyFrameInClip = inClip
            body = Piece(
                image: pose.image, frame: inClip.offsetBy(dx: bodyClip.minX, dy: bodyClip.minY), alpha: s.alpha
            )
        }

        let seated = seatRow.map { s.bodyX == 0 && s.bodyY == $0 } ?? false
        if s.shadowWidth > 0 && !seated {
            let width = CGFloat(s.shadowWidth)
            let height = max(2, u / 2)
            shadow = CGRect(x: bx + (bodyX + 9 - width / 2) * u, y: by - height, width: width * u, height: height)
        }

        var draws = s.props + s.particles
        if let accessory = s.accessory { draws.append(accessory) }
        if let badge = s.badge { draws.append(badge) }
        glyphs = draws.map { d in
            guard let image = atlas.glyph(d.glyph, color: d.color) else { return nil }
            let size = atlas.glyphSize(d.glyph)
            return Piece(
                image: image,
                frame: CGRect(
                    x: bx + CGFloat(d.x) * u,
                    y: by + (Self.groundRow - CGFloat(d.y) - CGFloat(size.height)) * u,
                    width: CGFloat(size.width) * u, height: CGFloat(size.height) * u
                ),
                alpha: d.alpha
            )
        }
    }
}

/// Draws a Critter into a Core Graphics context exactly as `CritterSpriteLayer` shows it (`SpriteLayout`): for still
/// pictures. The context is y up, like a bitmap context; scaled images stay crisp (no interpolation).
public enum SpriteDrawing {
    /// One thing `draw` does, in order, in the context's space.
    public enum Step: Equatable {
        case shadow(CGRect)
        /// The body, clipped to `clip`.
        case body(CGRect, clip: CGRect, alpha: Double)
        /// Glyph `index` of the layout's glyphs.
        case glyph(index: Int, CGRect, alpha: Double)
    }

    /// What `draw` does for `layout` with the ground origin at `ground`: the shadow, the body, then each glyph.
    public static func steps(_ layout: SpriteLayout, ground: CGPoint) -> [Step] {
        var out: [Step] = []
        if let shadow = layout.shadow { out.append(.shadow(shadow.offsetBy(dx: ground.x, dy: ground.y))) }
        if let body = layout.body {
            out.append(.body(
                body.frame.offsetBy(dx: ground.x, dy: ground.y),
                clip: layout.bodyClip.offsetBy(dx: ground.x, dy: ground.y), alpha: body.alpha
            ))
        }
        for (index, glyph) in layout.glyphs.enumerated() {
            guard let glyph else { continue }
            out.append(.glyph(index: index, glyph.frame.offsetBy(dx: ground.x, dy: ground.y), alpha: glyph.alpha))
        }
        return out
    }

    /// Draws `s` with its ground origin at `ground`, `unit` points (pixels in a bitmap) a cell.
    public static func draw(
        _ s: ActorSnapshot, atlas: SpriteAtlas, unit: CGFloat, seatRow: Int? = nil, ground: CGPoint,
        in context: CGContext
    ) {
        guard let layout = SpriteLayout(s, atlas: atlas, unit: unit, seatRow: seatRow) else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        for step in steps(layout, ground: ground) {
            switch step {
            case .shadow(let rect):
                context.setFillColor(CGColor(gray: 0, alpha: CGFloat(SpriteLayout.shadowOpacity)))
                context.fill(rect)
            case .body(let rect, let clip, let alpha):
                guard let image = layout.body?.image else { continue }
                context.saveGState()
                context.clip(to: clip)
                context.setAlpha(CGFloat(alpha))
                context.draw(image, in: rect)
                context.restoreGState()
            case .glyph(let index, let rect, let alpha):
                guard let image = layout.glyphs[index]?.image else { continue }
                context.saveGState()
                context.setAlpha(CGFloat(alpha))
                context.draw(image, in: rect)
                context.restoreGState()
            }
        }
    }
}
