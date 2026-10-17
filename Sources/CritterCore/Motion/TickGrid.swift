import Foundation

/// The animation clock's bookkeeping on the tick grid, with the time passed in: how many
/// whole ticks have passed since the last processed one, and when a change some ticks ahead
/// is due. The clock sleeps until the next change, so before anything outside a tick changes
/// what the actors do it must `take` the ticks slept so far -- otherwise the next wake would
/// step the new animation through the whole quiet spell.
public struct TickGrid: Sendable {
    /// Never sleep longer than this many ticks (the engine returns a huge sentinel when
    /// nothing changes on its own).
    public static let maxSleepTicks = 1000
    /// After a longer stall (system sleep) take this many ticks, then resync to now.
    public static let maxCatchUpTicks = 1000
    /// A wake right on a grid line may come a hair early in floating point.
    static let slack: TimeInterval = 0.002

    public let tick: TimeInterval
    /// When the last processed tick happened.
    public private(set) var lastTick: TimeInterval

    public init(tickMs: Int, start: TimeInterval) {
        tick = TimeInterval(max(1, tickMs)) / 1000
        lastTick = start
    }

    /// Starts counting afresh from `now` (the clock was stopped meanwhile).
    public mutating func restart(at now: TimeInterval) {
        lastTick = now
    }

    /// The whole ticks that have passed by `now` (0 if none), consumed: the grid moves on by
    /// that many, keeping its phase -- or, after a stall longer than `maxCatchUpTicks`, takes
    /// that many and resyncs to `now`.
    public mutating func take(now: TimeInterval) -> Int {
        let n = Int((now - lastTick + Self.slack) / tick)
        guard n >= 1 else { return 0 }
        if n > Self.maxCatchUpTicks {
            lastTick = now
            return Self.maxCatchUpTicks
        }
        lastTick += TimeInterval(n) * tick
        return n
    }

    /// When a change `ticks` after the last processed tick is due (1…`maxSleepTicks` ticks).
    public func due(afterTicks ticks: Int) -> TimeInterval {
        lastTick + TimeInterval(min(max(ticks, 1), Self.maxSleepTicks)) * tick
    }
}
