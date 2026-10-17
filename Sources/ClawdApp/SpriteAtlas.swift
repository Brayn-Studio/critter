import ClawdCore
import CoreGraphics

/// The skin's bitmaps, rendered once and reused for as long as the flock view lives: each
/// pose plain and dimmed (with the pixel grid that says where it sits in the base box), and
/// each glyph per color. One bitmap pixel per cell; layers scale them up with
/// nearest-neighbour filtering so the pixel art stays crisp.
final class SpriteAtlas {
    let skin: SkinManifest

    private struct PoseKey: Hashable {
        var name: String
        var dim: Bool
    }

    private struct GlyphKey: Hashable {
        var name: String
        var color: String
    }

    /// nil entries remember unknown or empty poses/glyphs, so they aren't retried every tick.
    private var poses: [PoseKey: (image: CGImage, grid: PixelGrid)?] = [:]
    private var glyphs: [GlyphKey: CGImage?] = [:]

    init(skin: SkinManifest) {
        self.skin = skin
    }

    /// `name`'s bitmap (dimmed for the `dim` tint) and its grid, or nil for an unknown pose.
    func pose(_ name: String, dim: Bool) -> (image: CGImage, grid: PixelGrid)? {
        let key = PoseKey(name: name, dim: dim)
        if let cached = poses[key] { return cached }
        var entry: (image: CGImage, grid: PixelGrid)?
        if let grid = SkinRenderer.grid(pose: name, in: skin),
           let image = SkinRenderer.image(grid, palette: skin.palette, dim: dim) {
            entry = (image, grid)
        }
        poses[key] = entry
        return entry
    }

    /// The glyph `name` drawn in `color` (`#RRGGBB`), or nil for an unknown glyph.
    func glyph(_ name: String, color: String) -> CGImage? {
        let key = GlyphKey(name: name, color: color)
        if let cached = glyphs[key] { return cached }
        let image = skin.glyphs[name].flatMap { SkinRenderer.glyphImage($0, color: color) }
        glyphs[key] = image
        return image
    }

    /// A glyph's width and height in cells (0 × 0 for an unknown glyph).
    func glyphSize(_ name: String) -> (width: Int, height: Int) {
        let rows = skin.glyphs[name] ?? []
        return (rows.first?.count ?? 0, rows.count)
    }
}
