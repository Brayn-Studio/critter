import CoreGraphics
import Foundation

/// The stepped outline every surface shares with the pet's body (visual design §4, Android `pixelOutline`): two
/// steps of `step` at each corner.
public enum PixelOutline {
    /// The vertices, clockwise in y-down coordinates, starting at the lower point of the top-left corner: 20
    /// points, or 12 with `topOnly` (square bottom corners, for sheets). `step` is clamped to a quarter of the
    /// shorter side, so the four steps of two corners always fit.
    public static func points(width w: CGFloat, height h: CGFloat, step: CGFloat, topOnly: Bool = false) -> [CGPoint] {
        let s = min(step, (min(w, h) / 4).rounded(.down))
        var points = [
            (0, 2 * s), (s, 2 * s), (s, s), (2 * s, s), (2 * s, 0),
            (w - 2 * s, 0), (w - 2 * s, s), (w - s, s), (w - s, 2 * s), (w, 2 * s),
        ]
        if topOnly {
            points += [(w, h), (0, h)]
        } else {
            points += [
                (w, h - 2 * s), (w - s, h - 2 * s), (w - s, h - s), (w - 2 * s, h - s), (w - 2 * s, h),
                (2 * s, h), (2 * s, h - s), (s, h - s), (s, h - 2 * s), (0, h - 2 * s),
            ]
        }
        return points.map { CGPoint(x: $0.0, y: $0.1) }
    }
}
