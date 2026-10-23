/// Delays between reconnect attempts: `initial`, doubling each time, capped at `max`.
public struct ReconnectBackoff: Sendable {
    private let initial: Duration
    private let max: Duration
    private var next: Duration

    public init(initial: Duration = .seconds(2), max: Duration = .seconds(60)) {
        self.initial = initial
        self.max = max
        next = initial
    }

    /// The delay to wait before the next attempt; each call advances the schedule.
    public mutating func nextDelay() -> Duration {
        let delay = next
        next = Swift.min(next * 2, max)
        return delay
    }

    /// Call after a successful connection.
    public mutating func reset() {
        next = initial
    }
}
