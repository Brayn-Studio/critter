import Foundation

public enum GazeZone: Equatable, Sendable {
    case left, right, up, down, center
}

/// Where a Critter looks for a pointer position — design §4.11.
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

/// Recognises rubbing back and forth over a Critter: 3 direction reversals within a second,
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

/// Where the pointer counts as being on a Critter — design §4.11 (and the preview's `actorAt`).
public enum MotionHover {
    /// Whether `pointer` is over the Critter whose base box meets the ground at `anchor` (column
    /// 0; AppKit coordinates, y up), drawn `offset` cells away while following: columns 1…17
    /// of the box, from 2 pt below the ground to 11 cells above it. With `pile`, the whole
    /// merged pile instead: from 1 cell left of the front Critter to 27 cells right, up to 13
    /// cells above the ground.
    public static func contains(pointer: CGPoint, anchor: CGPoint, unit u: CGFloat,
                                offset: (x: Int, y: Int) = (0, 0), pile: Bool = false) -> Bool {
        let x = anchor.x + CGFloat(offset.x) * u
        let ground = anchor.y + CGFloat(offset.y) * u
        let (left, right, top): (CGFloat, CGFloat, CGFloat) = pile ? (-1, 27, 13) : (1, 17, 11)
        return pointer.x >= x + left * u && pointer.x <= x + right * u
            && pointer.y >= ground - 2 && pointer.y <= ground + top * u
    }
}

/// The held Critter's sideways swing while dragged — design §4.10.
public enum MotionDrag {
    /// Lag in cells for a pointer that just moved `pointerDx` points sideways: it trails the
    /// move, a cell per 3 pt, at most 3 cells either way.
    public static func lag(pointerDx: CGFloat) -> Int {
        Swift.min(Swift.max(jsRound(-Double(pointerDx) / 3), -3), 3)
    }

    /// One tick of settling with the pointer at rest: a cell back toward 0.
    public static func settle(_ lag: Int) -> Int {
        lag - lag.signum()
    }
}
