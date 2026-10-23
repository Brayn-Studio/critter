import Foundation

/// A glyph to draw: `x`, `y` are its top-left cell in base-box coordinates (y down, ground =
/// row 10), relative to the actor's anchor plus its follow offset, with lag, lift and (for
/// particles and props) the key's dx already applied.
public struct GlyphDraw: Equatable, Sendable {
    public var glyph: String
    public var color: String
    public var x: Int
    public var y: Int
    public var alpha: Double

    public init(glyph: String, color: String, x: Int, y: Int, alpha: Double) {
        self.glyph = glyph
        self.color = color
        self.x = x
        self.y = y
        self.alpha = alpha
    }
}

/// Everything needed to draw one actor for one tick; equal snapshots draw identically.
public struct ActorSnapshot: Equatable, Sendable {
    public var hidden: Bool
    public var pose: String
    /// Key dx + lag, in cells.
    public var bodyX: Int
    /// Key dy + lift, in cells, up positive; decides the ground clipping.
    public var bodyY: Int
    /// Follow offset in cells, up positive.
    public var offsetX: Int
    public var offsetY: Int
    public var tint: Tint?
    public var alpha: Double
    public var z: Int
    /// Shadow width in cells; 0 = no shadow.
    public var shadowWidth: Int
    public var accessory: GlyphDraw?
    public var badge: GlyphDraw?
    public var particles: [GlyphDraw]
    public var props: [GlyphDraw]

    public init(hidden: Bool, pose: String, bodyX: Int, bodyY: Int, offsetX: Int, offsetY: Int,
                tint: Tint?, alpha: Double, z: Int, shadowWidth: Int, accessory: GlyphDraw?,
                badge: GlyphDraw?, particles: [GlyphDraw], props: [GlyphDraw]) {
        self.hidden = hidden
        self.pose = pose
        self.bodyX = bodyX
        self.bodyY = bodyY
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.tint = tint
        self.alpha = alpha
        self.z = z
        self.shadowWidth = shadowWidth
        self.accessory = accessory
        self.badge = badge
        self.particles = particles
        self.props = props
    }
}
