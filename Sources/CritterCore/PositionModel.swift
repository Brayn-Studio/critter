import CoreGraphics
import Foundation

/// Where the pet window is pinned, in screen coordinates (AppKit, bottom-left origin): the
/// window's bottom edge sits at `y`, and its left (`.left`) or right (`.right`) edge at `x`.
/// The flock grows away from the pinned side as sessions come and go, so the corner the
/// user dragged it to stays put.
public struct Anchor: Codable, Equatable, Sendable {
    public enum Side: String, Codable, Sendable {
        case left, right
    }

    public var side: Side
    public var x: CGFloat
    public var y: CGFloat

    public init(side: Side, x: CGFloat, y: CGFloat) {
        self.side = side
        self.x = x
        self.y = y
    }
}

/// Pure position math for the pet window: deriving the anchor from where the user dropped
/// it, turning an anchor back into a frame for the window's current size, and pulling that
/// frame back on screen when displays change (an external monitor unplugged, a resolution
/// change) so the pet can never end up out of reach.
public enum PositionModel {
    /// The minimum gap kept between the window and the edges of the visible area.
    public static let margin: CGFloat = 4
    /// The default spot's distance from the bottom-right corner of the visible area.
    public static let defaultInset: CGFloat = 24

    /// A frame whose center is on the left half of `screen` is pinned by its left edge;
    /// otherwise by its right edge. Either way by its bottom edge.
    public static func anchor(for frame: CGRect, in screen: CGRect) -> Anchor {
        if frame.midX < screen.midX {
            return Anchor(side: .left, x: frame.minX, y: frame.minY)
        }
        return Anchor(side: .right, x: frame.maxX, y: frame.minY)
    }

    /// The window frame for `size` pinned at `anchor`, clamped into `visible` with a
    /// `margin` all around. A window larger than the visible area (along an axis) is
    /// pinned to its bottom/left edge.
    public static func frame(size: CGSize, anchor: Anchor, visible: CGRect) -> CGRect {
        let x = anchor.side == .left ? anchor.x : anchor.x - size.width
        let bounds = visible.insetBy(dx: margin, dy: margin)
        return CGRect(
            x: clamp(x, length: size.width, min: bounds.minX, max: bounds.maxX),
            y: clamp(anchor.y, length: size.height, min: bounds.minY, max: bounds.maxY),
            width: size.width,
            height: size.height
        )
    }

    /// The widest window that fits in `visible` with a `margin` on both sides.
    public static func usableWidth(of visible: CGRect) -> CGFloat {
        visible.width - 2 * margin
    }

    /// Bottom-right corner of the visible area, inset by 24 pt.
    public static func defaultAnchor(visible: CGRect) -> Anchor {
        Anchor(side: .right, x: visible.maxX - defaultInset, y: visible.minY + defaultInset)
    }

    /// The index of the screen (by full frame) the anchor sits on, or nil if it's on none of
    /// them any more -- the caller then falls back to the main screen. A right-side anchor
    /// lies on its screen's right edge, so the point probed is just inside the window.
    public static func screenIndex(for anchor: Anchor, screens: [CGRect]) -> Int? {
        let probe = CGPoint(x: anchor.side == .left ? anchor.x + 0.5 : anchor.x - 0.5, y: anchor.y + 0.5)
        return screens.firstIndex { $0.contains(probe) }
    }

    private static func clamp(_ origin: CGFloat, length: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        guard length <= upper - lower else { return lower }
        return Swift.min(Swift.max(origin, lower), upper - length)
    }
}
