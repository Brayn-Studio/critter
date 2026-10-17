import Foundation

public enum GazeZone: Equatable, Sendable {
    case left, right, up, down, center
}

/// Where a Clawd looks for a pointer position — design §4.11.
public enum MotionGaze {
    /// `pointer` and `center` (anchor + (9u, 7u)) in AppKit coordinates, y up; nil when the
    /// pointer is too far away to care.
    public static func zone(pointer: CGPoint, center: CGPoint, unit: CGFloat) -> GazeZone? {
        let dx = pointer.x - center.x
        let below = center.y - pointer.y       // the preview measures y downward
        if hypot(dx, below) > 170 { return nil }
        if below < -max(28, abs(dx) * 1.1) { return .up }
        if dx < -6 * unit { return .left }
        if dx > 6 * unit { return .right }
        return below > 10 ? .down : .center
    }
}

/// Recognises rubbing back and forth over a Clawd: 3 direction reversals within a second,
/// counting only horizontal moves of 3 pt or more.
public struct RubDetector: Sendable {
    private var lastX: CGFloat?
    private var direction: CGFloat = 0
    private var reversals: [TimeInterval] = []
    private var lastMove: TimeInterval?

    public init() {}

    /// Feeds a pointer position; returns whether this counts as rubbing now.
    public mutating func move(x: CGFloat, at t: TimeInterval) -> Bool {
        if let lastX {
            let dx = x - lastX
            if abs(dx) >= 3 {
                let d: CGFloat = dx > 0 ? 1 : -1
                if direction != 0 && d != direction { reversals.append(t) }
                direction = d
                self.lastX = x
                lastMove = t
            }
        } else {
            lastX = x
        }
        reversals.removeAll { t - $0 >= 1 }
        return reversals.count >= 3
    }

    /// True once 0.7 s passed since the last counted move.
    public func shouldEnd(at t: TimeInterval) -> Bool {
        guard let lastMove else { return false }
        return t - lastMove > 0.7
    }

    public mutating func reset() { self = RubDetector() }
}
