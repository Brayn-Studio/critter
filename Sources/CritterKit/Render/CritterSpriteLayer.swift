import QuartzCore

/// Draws one Critter's `ActorSnapshot` with plain Core Animation layers: a shadow, the body
/// (clipped at the ground, so a sinking pose disappears into it), and a pool of small glyph
/// layers reused for the head marker, the waiting badge, particles and props. Where each goes is
/// `SpriteLayout`'s (which `SpriteDrawing` also draws still pictures by).
///
/// The layer itself sits at `groundOrigin` (zero size, not clipping) and everything inside
/// is placed relative to it, in cells of `unit` points; y grows upward like the host view.
/// Nothing animates implicitly: every change happens in an actions-disabled transaction, and
/// a snapshot equal to the previous one is skipped entirely.
public final class CritterSpriteLayer: CALayer {
    /// The bitmaps of the skin this Critter wears.
    public let atlas: SpriteAtlas
    private let unit: CGFloat
    // Internal (not private) for the tests that compare them with `SpriteDrawing`.
    let shadowLayer = CALayer()
    let clipLayer = CALayer()
    let bodyLayer = CALayer()
    /// Reused glyph layers, in drawing order (later ones on top).
    private(set) var glyphLayers: [CALayer] = []
    private var last: ActorSnapshot?

    /// View coordinates of the point where the base box's column 0 meets the ground.
    public var groundOrigin: CGPoint = .zero {
        didSet {
            guard groundOrigin != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            position = groundOrigin
            CATransaction.commit()
        }
    }

    /// Set while this Critter sits in (or hops to) pile row `seatRow`: once seated it casts no
    /// shadow, exactly like the still pile it turns into.
    public var seatRow: Int? {
        didSet { if seatRow != oldValue { last = nil } }
    }

    public init(atlas: SpriteAtlas, unit: CGFloat) {
        self.atlas = atlas
        self.unit = unit
        super.init()
        anchorPoint = .zero
        bounds = .zero
        position = .zero
        masksToBounds = false

        shadowLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        shadowLayer.opacity = SpriteLayout.shadowOpacity
        shadowLayer.isHidden = true
        addSublayer(shadowLayer)

        clipLayer.masksToBounds = true
        addSublayer(clipLayer)
        bodyLayer.magnificationFilter = .nearest
        bodyLayer.minificationFilter = .nearest
        clipLayer.addSublayer(bodyLayer)
    }

    public required init?(coder: NSCoder) {
        fatalError("CritterSpriteLayer does not support NSCoding")
    }

    /// Core Animation copies layers (presentation layers); the copy only needs to draw.
    public override init(layer: Any) {
        guard let other = layer as? CritterSpriteLayer else {
            fatalError("CritterSpriteLayer(layer:) given a layer of the wrong type")
        }
        atlas = other.atlas
        unit = other.unit
        super.init(layer: layer)
    }

    /// Whether `s` would change anything on screen.
    public func needsRender(_ s: ActorSnapshot) -> Bool {
        s != last
    }

    /// Draws `s`. Cheap when nothing changed.
    public func render(_ s: ActorSnapshot) {
        guard s != last else { return }
        last = s
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        isHidden = s.hidden
        zPosition = CGFloat(s.z)
        guard let layout = SpriteLayout(s, atlas: atlas, unit: unit, seatRow: seatRow) else { return }

        clipLayer.frame = layout.bodyClip
        if let body = layout.body, let frame = layout.bodyFrameInClip {
            bodyLayer.contents = body.image
            bodyLayer.frame = frame
            bodyLayer.opacity = Float(body.alpha)
            bodyLayer.isHidden = false
        } else {
            bodyLayer.isHidden = true
        }

        if let shadow = layout.shadow {
            shadowLayer.frame = shadow
            shadowLayer.isHidden = false
        } else {
            shadowLayer.isHidden = true
        }

        while glyphLayers.count < layout.glyphs.count {
            let layer = CALayer()
            layer.magnificationFilter = .nearest
            layer.minificationFilter = .nearest
            addSublayer(layer)
            glyphLayers.append(layer)
        }
        for (index, layer) in glyphLayers.enumerated() {
            guard index < layout.glyphs.count, let glyph = layout.glyphs[index] else {
                layer.isHidden = true
                continue
            }
            layer.contents = glyph.image
            layer.frame = glyph.frame
            layer.opacity = Float(glyph.alpha)
            layer.isHidden = false
        }
    }
}
