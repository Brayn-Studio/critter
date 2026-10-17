import CritterCore
import Foundation

/// The flock's tick source: a main-thread timer on the skin's tick grid (60 ms) that only
/// wakes on the tick where the picture can next change. `onTick(n)` advances `n` ticks
/// (0 = just redraw), draws, and returns how many ticks until something changes again; the
/// timer then sleeps that long -- skipped ticks are caught up on the next wake, so counters
/// like the idle-to-sleep timer keep running. Stopped while the pet is hidden.
///
/// Anything that changes what the actors do from outside a tick must `catchUp()` first, so
/// the ticks slept so far are spent on the old animation, not on the new one.
@MainActor
final class MotionClock {
    var onTick: ((Int) -> Int)?
    private(set) var isRunning = false

    private var grid: TickGrid
    private var timer: Timer?

    init(tickMs: Int) {
        grid = TickGrid(tickMs: tickMs, start: ProcessInfo.processInfo.systemUptime)
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        grid.restart(at: Self.now)
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

    /// Steps the actors through the whole ticks slept so far (if any), right now.
    func catchUp() {
        guard isRunning else { return }
        let ticks = grid.take(now: Self.now)
        guard ticks > 0 else { return }
        schedule(onTick?(ticks) ?? TickGrid.maxSleepTicks)
    }

    /// Redraws now (`onTick(0)`) and re-aims the timer -- after anything outside the clock
    /// changed what the actors do (having caught up first). Also draws while stopped,
    /// without scheduling.
    func poke() {
        schedule(onTick?(0) ?? TickGrid.maxSleepTicks)
    }

    private func fire() {
        guard isRunning else { return }
        let ticks = grid.take(now: Self.now)
        guard ticks > 0 else {
            schedule(1)
            return
        }
        schedule(onTick?(ticks) ?? TickGrid.maxSleepTicks)
    }

    private func schedule(_ ticks: Int) {
        guard isRunning, let timer else { return }
        timer.fireDate = Date(timeIntervalSinceNow: max(0, grid.due(afterTicks: ticks) - Self.now))
    }
}
