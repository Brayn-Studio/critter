import CritterCore
import QuartzCore

/// Draws one Critter's `ActorSnapshot` with plain Core Animation layers: a shadow, the body
/// (clipped at the ground, so a sinking pose disappears into it), and a pool of small glyph
/// layers reused for the head marker, the waiting badge, particles and props.
///
/// The layer itself sits at `groundOrigin` (zero size, not clipping) and everything inside
/// is placed relative to it, in cells of `unit` points; y grows upward like the host view.
/// Nothing animates implicitly: every change happens in an actions-disabled transaction, and
/// a snapshot equal to the previous one is skipped entirely.
final class CritterSpriteLayer: CALayer {
    /// The body clip reaches this far above the ground...
    private static let clipHeightCells: CGFloat = 40
    /// ...and this far to either side of the 18-cell base box.
    private static let clipMarginCells: CGFloat = 12
    private static let baseColumns: CGFloat = 18
    private static let groundRow: CGFloat = 10
    private static let shadowOpacity: Float = 0.28

    private let atlas: SpriteAtlas
    private let unit: CGFloat
    private let shadowLayer = CALayer()
    private let clipLayer = CALayer()
    private let bodyLayer = CALayer()
    /// Reused glyph layers, in drawing order (later ones on top).
    private var glyphLayers: [CALayer] = []
    private var last: ActorSnapshot?

    /// View coordinates of the point where the base box's column 0 meets the ground.
    var groundOrigin: CGPoint = .zero {
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
    var seatRow: Int? {
        didSet { if seatRow != oldValue { last = nil } }
    }

    init(atlas: SpriteAtlas, unit: CGFloat) {
        self.atlas = atlas
        self.unit = unit
        super.init()
        anchorPoint = .zero
        bounds = .zero
        position = .zero
        masksToBounds = false

        shadowLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        shadowLayer.opacity = Self.shadowOpacity
        shadowLayer.isHidden = true
        addSublayer(shadowLayer)

        clipLayer.masksToBounds = true
        addSublayer(clipLayer)
        bodyLayer.magnificationFilter = .nearest
        bodyLayer.minificationFilter = .nearest
        clipLayer.addSublayer(bodyLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("CritterSpriteLayer does not support NSCoding")
    }

    /// Core Animation copies layers (presentation layers); the copy only needs to draw.
    override init(layer: Any) {
        guard let other = layer as? CritterSpriteLayer else {
            fatalError("CritterSpriteLayer(layer:) given a layer of the wrong type")
        }
        atlas = other.atlas
        unit = other.unit
        super.init(layer: layer)
    }

    /// Whether `s` would change anything on screen.
    func needsRender(_ s: ActorSnapshot) -> Bool {
        s != last
    }

    /// Draws `s`. Cheap when nothing changed.
    func render(_ s: ActorSnapshot) {
        guard s != last else { return }
        last = s
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        isHidden = s.hidden
        zPosition = CGFloat(s.z)
        guard !s.hidden else { return }

        let u = unit
        // B: the anchor plus the follow offset, relative to `groundOrigin`.
        let bx = CGFloat(s.offsetX) * u
        let by = CGFloat(s.offsetY) * u
        let bodyX = CGFloat(s.bodyX)

        // Body: clipped at the ground; the clip travels with the key's dx.
        clipLayer.frame = CGRect(
            x: bx + (bodyX - Self.clipMarginCells) * u, y: by,
            width: (Self.baseColumns + 2 * Self.clipMarginCells) * u, height: Self.clipHeightCells * u
        )
        if let pose = atlas.pose(s.pose, dim: s.tint == .dim) {
            let grid = pose.grid
            bodyLayer.contents = pose.image
            bodyLayer.frame = CGRect(
                x: (CGFloat(grid.minX) + Self.clipMarginCells) * u,
                y: (Self.groundRow - CGFloat(grid.minY) - CGFloat(grid.height) + CGFloat(s.bodyY)) * u,
                width: CGFloat(grid.width) * u, height: CGFloat(grid.height) * u
            )
            bodyLayer.opacity = Float(s.alpha)
            bodyLayer.isHidden = false
        } else {
            bodyLayer.isHidden = true
        }

        // Shadow: just below the ground, centred under the body.
        let seated = seatRow.map { s.bodyX == 0 && s.bodyY == $0 } ?? false
        if s.shadowWidth > 0 && !seated {
            let width = CGFloat(s.shadowWidth)
            let height = max(2, u / 2)
            shadowLayer.frame = CGRect(x: bx + (bodyX + 9 - width / 2) * u, y: by - height, width: width * u, height: height)
            shadowLayer.isHidden = false
        } else {
            shadowLayer.isHidden = true
        }

        // Glyphs, bottom to top: props, particles, head marker, badge. Never clipped.
        var draws = s.props + s.particles
        if let accessory = s.accessory { draws.append(accessory) }
        if let badge = s.badge { draws.append(badge) }
        while glyphLayers.count < draws.count {
            let layer = CALayer()
            layer.magnificationFilter = .nearest
            layer.minificationFilter = .nearest
            addSublayer(layer)
            glyphLayers.append(layer)
        }
        for (index, layer) in glyphLayers.enumerated() {
            guard index < draws.count, let image = atlas.glyph(draws[index].glyph, color: draws[index].color) else {
                layer.isHidden = true
                continue
            }
            let d = draws[index]
            let size = atlas.glyphSize(d.glyph)
            layer.contents = image
            layer.frame = CGRect(
                x: bx + CGFloat(d.x) * u,
                y: by + (Self.groundRow - CGFloat(d.y) - CGFloat(size.height)) * u,
                width: CGFloat(size.width) * u, height: CGFloat(size.height) * u
            )
            layer.opacity = Float(d.alpha)
            layer.isHidden = false
        }
    }
}
