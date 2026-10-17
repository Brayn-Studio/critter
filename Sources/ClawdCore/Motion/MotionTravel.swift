import Foundation

/// Hopping from one place to another (expand, collapse, scoot) — design §4.8.
public enum MotionTravel {
    /// Engine-internal effect on the last key of a hop into the pile: applies the seat.
    static let seatEffect = "@seat"

    /// Keys that hop from (`fromDx`, `fromDy`) cells relative to the target back to
    /// (0, `toDy`): wait `delay` ticks, then 4-tick hops of at most `hopLength` cells each,
    /// then land (on the ground, or raised `toDy` rows onto the back of the pile).
    /// A port of the preview's `travelKeys`.
    public static func keys(fromDx: Int, fromDy: Int, toDy: Int, delay: Int, hopLength: Int,
                            names: InteractionNames) -> MotionClip {
        var keys: MotionClip = []
        if delay > 0 { keys.append(ClipKey(pose: names.land, ticks: delay, dx: fromDx, dy: fromDy)) }
        let hops = max(1, Int(ceil(Double(abs(fromDx)) / Double(max(1, hopLength)))))
        let n = hops * 4
        let arc = [2, 3, 2, 0]
        let poses = [names.hop, names.hop, names.hop, names.land]
        for i in 1...n {
            let p = Double(i) / Double(n), j = (i - 1) % 4
            keys.append(ClipKey(pose: poses[j], ticks: 1, dx: jsRound(Double(fromDx) * (1 - p)),
                                dy: jsRound(Double(fromDy) * (1 - p) + Double(toDy) * p) + arc[j]))
        }
        if toDy > 0 {
            keys.append(ClipKey(pose: names.land, ticks: 1, dx: 0, dy: toDy - 1, effect: names.landDust))
            keys.append(ClipKey(pose: names.land, ticks: 1, dx: 0, dy: toDy, effect: seatEffect))
        } else {
            keys.append(ClipKey(pose: names.land, ticks: 2, dx: 0, dy: -2, effect: names.landDust))
            keys.append(ClipKey(pose: names.land, ticks: 1))
            keys.append(ClipKey(pose: names.blinkPose, ticks: 1))
        }
        return keys
    }
}

/// Where a Clawd sits in the pile: `row` cells up (and 4·row right), dimmed to `alpha`, at layer `z`.
public struct Seat: Equatable, Sendable {
    public var row: Int
    public var alpha: Double
    public var z: Int

    public init(row: Int, alpha: Double, z: Int) {
        self.row = row
        self.alpha = alpha
        self.z = z
    }
}

/// Seating the flock into the pile one by one as it collapses — design §4.9.
public enum PileSeating {
    /// Rows behind the lead: at most 2.
    public static func backRows(total: Int) -> Int { max(0, min(2, total - 1)) }

    /// Row per id: the lead stands in front (0); the others, in departure order, take the
    /// farthest back row first (nb, nb − 1, …), then all sit in row 1.
    public static func seats(departureOrder: [String], lead: String, total: Int) -> [String: Int] {
        let nb = backRows(total: total)
        var out: [String: Int] = [lead: 0]
        var j = 0
        for id in departureOrder where id != lead {
            out[id] = j < nb ? nb - j : 1
            j += 1
        }
        return out
    }

    public static func seat(row: Int) -> Seat { Seat(row: row, alpha: row == 2 ? 0.55 : 0.75, z: 2 - row) }
}
