import Foundation

/// The flock's tick source: a main-thread timer on the skin's tick grid (60 ms) that only
/// wakes on the tick where the picture can next change. `onTick(n)` advances `n` ticks
/// (0 = just redraw), draws, and returns how many ticks until something changes again; the
/// timer then sleeps that long -- skipped ticks are caught up on the next wake, so counters
/// like the idle-to-sleep timer keep running. Stopped while the pet is hidden.
@MainActor
final class MotionClock {
    /// Never sleep longer than this many ticks, whatever `onTick` says (the engine returns a
    /// huge sentinel when nothing changes on its own).
    static let maxSleepTicks = 1000
    /// After a long stall (system sleep) catch up at most this many ticks, then resync.
    static let maxCatchUpTicks = 1000

    var onTick: ((Int) -> Int)?
    private(set) var isRunning = false

    private let tick: TimeInterval
    private var timer: Timer?
    /// `systemUptime` of the last tick processed; wakes are scheduled on this grid.
    private var lastTick: TimeInterval = 0

    init(tickMs: Int) {
        tick = TimeInterval(max(1, tickMs)) / 1000
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastTick = ProcessInfo.processInfo.systemUptime
        // One long-lived timer, re-aimed through `fireDate`: no allocation per wake.
        let timer = Timer(fire: .distantFuture, interval: 365 * 24 * 3600, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            // Safe: only ever added to `RunLoop.main`, so it fires on the main thread.
            MainActor.assumeIsolated { self.fire() }
        }
        timer.tolerance = 0.010
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poke()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    /// Redraws now (`onTick(0)`) and re-aims the timer -- after anything outside the clock
    /// changed what the actors do. Also draws while stopped, without scheduling.
    func poke() {
        let next = onTick?(0) ?? Self.maxSleepTicks
        schedule(next)
    }

    private func fire() {
        guard isRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // A hair of slack so a timer that fires right on the grid line counts that tick.
        var n = Int(((now - lastTick) + 0.002) / tick)
        guard n >= 1 else {
            schedule(1)
            return
        }
        if n > Self.maxCatchUpTicks {
            n = Self.maxCatchUpTicks
            lastTick = now
        } else {
            lastTick += TimeInterval(n) * tick
        }
        let next = onTick?(n) ?? Self.maxSleepTicks
        schedule(next)
    }

    private func schedule(_ ticks: Int) {
        guard isRunning, let timer else { return }
        let wait = TimeInterval(min(max(ticks, 1), Self.maxSleepTicks)) * tick
        let delay = lastTick + wait - ProcessInfo.processInfo.systemUptime
        timer.fireDate = Date(timeIntervalSinceNow: max(0, delay))
    }
}
