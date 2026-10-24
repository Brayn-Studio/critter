/// When the landscape board opens and closes by itself (spec §8.6): it opens once the phone has been charging,
/// lying in landscape and still for `holdMs` with the screen on; it closes `unplugExitMs` after the charger is
/// pulled, or once the phone has stood upright for `uprightExitMs` (lying flat does not close it). A board the
/// user closed stays closed until the next plug-in, and so does one the system would not show: an `Action.open`
/// that is not followed by `onBoardShown(_:)` within `openTimeoutMs` stops the asking until the charger is plugged
/// in again, and is reported once as `Action.blocked`.
///
/// "Shown" means the board exists, from its creation to its destruction: a board whose screen was switched off is
/// still shown, so it is neither opened again nor left behind when the charger is pulled.
///
/// Pure and single-threaded: the caller passes a monotonic clock (milliseconds) and calls `onTick(nowMs:)` at
/// `nextDeadline()`. Ported from the Android app's `BoardTrigger`, rule for rule. Gravity is in m/s² like
/// Android's sensor; CoreMotion's units of g are scaled by the caller. `Action.blocked` never comes out of an
/// iPhone's foreground app (the board can always be shown), but the rule stays for parity.
public final class BoardTrigger {
    public enum Action: Equatable, Sendable {
        case open
        case close
        /// The last `open` never came up, or could not be started: the system kept the board from opening.
        case blocked
        case none
    }

    /// How the phone is held, from gravity.
    public enum Pose: Equatable, Sendable {
        case landscape
        case upright
        case other
    }

    private let holdMs: Int64
    private let unplugExitMs: Int64
    private let uprightExitMs: Int64
    private let openTimeoutMs: Int64

    private var charging = false
    private var screenOn = true
    private var shown = false
    private var suppressed = false

    /// Whether the board may open by itself (the setting); closing works either way. Switched off, a hold in
    /// progress is forgotten: its deadline would only come round to an open that can no longer happen (a caller
    /// that sleeps until `nextDeadline()` would wake up to it again and again). Switched on again, the hold starts
    /// afresh from the next still reading.
    public var autoOpen = true {
        didSet {
            if !autoOpen { holdSince = nil }
        }
    }

    /// Since when the phone has been charging, landscape and still (while the board is not up).
    private var holdSince: Int64?

    /// The earliest a hold may count from: the last plug-in or screen-on.
    private var holdFloor = Int64.min

    /// Since when the phone has been upright (while the board is up).
    private var uprightSince: Int64?

    /// When the charger was pulled (while the board is up).
    private var unpluggedAt: Int64?

    /// When the last `Action.open` went out, until the board comes up.
    private var openedAt: Int64?

    private let stillness = Stillness()

    public init(holdMs: Int64 = 3_000, unplugExitMs: Int64 = 10_000, uprightExitMs: Int64 = 3_000,
                openTimeoutMs: Int64 = 2_000) {
        self.holdMs = holdMs
        self.unplugExitMs = unplugExitMs
        self.uprightExitMs = uprightExitMs
        self.openTimeoutMs = openTimeoutMs
    }

    /// An `Action.open` went out and has neither come up nor been given up on (the 2 s timeout, a failed start, the
    /// charger pulled): a board that comes up now is the one it opened, not one the user opened by hand.
    public var awaitingOpen: Bool { openedAt != nil }

    /// The gravity sensor is needed only while charging with the screen on (no readings arrive with it off), and
    /// only to open a board or to close one that is up.
    public var sensorWanted: Bool { charging && screenOn && (shown || (autoOpen && !suppressed)) }

    public func onPower(charging: Bool, nowMs: Int64) -> Action {
        if charging == self.charging { return evaluate(nowMs) }
        self.charging = charging
        if charging {
            // A new plug-in lifts the suppression a manual exit (or a refused opening) put on this charge.
            suppressed = false
            unpluggedAt = nil
            uprightSince = nil
            holdFloor = nowMs
        } else {
            holdSince = nil
            openedAt = nil
            if shown { unpluggedAt = nowMs }
        }
        return evaluate(nowMs)
    }

    /// The screen went on or off. Nothing opens while it is off, and the pose is unknown until it is back on.
    public func onScreen(on: Bool, nowMs: Int64) -> Action {
        if on == screenOn { return evaluate(nowMs) }
        screenOn = on
        holdSince = nil
        uprightSince = nil
        if on { holdFloor = nowMs }
        return evaluate(nowMs)
    }

    /// How the phone lies now. `stillSinceMs`: since when it has been still, if `still` (the hold counts from
    /// there: the time it took to see that the phone is still is part of the hold, not added to it). Defaults to
    /// `nowMs`.
    public func onOrientation(pose: Pose, still: Bool, nowMs: Int64, stillSinceMs: Int64? = nil) -> Action {
        if !charging || !screenOn { return evaluate(nowMs) }
        if shown {
            if pose == .upright {
                if uprightSince == nil { uprightSince = nowMs }
            } else {
                uprightSince = nil
            }
        } else if pose == .landscape && still && autoOpen && !suppressed {
            // Not from before this charge or this screen-on: only since then does lying still count.
            if holdSince == nil { holdSince = min(max(stillSinceMs ?? nowMs, holdFloor), nowMs) }
        } else {
            holdSince = nil
        }
        return evaluate(nowMs)
    }

    /// A gravity reading in m/s² (the sensor runs only while `sensorWanted`): its pose, and whether the phone has
    /// been still (see `Stillness`).
    public func onGravity(x: Double, y: Double, z: Double, nowMs: Int64) -> Action {
        let still = stillness.add(nowMs: nowMs, x: x, y: y, z: z)
        return onOrientation(pose: Self.poseOf(gx: x, gy: y, gz: z), still: still, nowMs: nowMs,
                             stillSinceMs: stillness.stillSince ?? nowMs)
    }

    /// The gravity sensor was started (again): what it read before says nothing about now.
    public func onSensorStarted() {
        stillness.clear()
    }

    public func onTick(nowMs: Int64) -> Action { evaluate(nowMs) }

    /// The user left the board: no automatic opening until the charger is plugged in again.
    public func onManualExit(nowMs: Int64) {
        suppressed = true
        holdSince = nil
        uprightSince = nil
        unpluggedAt = nil
    }

    /// The board could not be started at all: same as an opening the system never showed, so `Action.blocked`.
    public func onOpenFailed() -> Action {
        suppressed = true
        openedAt = nil
        holdSince = nil
        return .blocked
    }

    public func onBoardShown(_ shown: Bool) {
        if shown { openedAt = nil }
        if shown == self.shown { return }
        self.shown = shown
        holdSince = nil
        uprightSince = nil
        if !shown { unpluggedAt = nil }
    }

    /// The next time `onTick(nowMs:)` has something to decide, or nil.
    public func nextDeadline() -> Int64? {
        [
            holdSince.map { $0 + holdMs },
            uprightSince.map { $0 + uprightExitMs },
            unpluggedAt.map { $0 + unplugExitMs },
            openedAt.map { $0 + openTimeoutMs },
        ].compactMap { $0 }.min()
    }

    private func evaluate(_ nowMs: Int64) -> Action {
        if let opened = openedAt, !shown, nowMs - opened >= openTimeoutMs {
            // Asked, and nothing came up: the system blocks it. Retrying every few seconds would only burn power.
            openedAt = nil
            suppressed = true
            holdSince = nil
            return .blocked
        }
        if let hold = holdSince, !shown, charging, screenOn, autoOpen, !suppressed, nowMs - hold >= holdMs {
            // Needs a fresh hold before it asks again.
            holdSince = nil
            openedAt = nowMs
            return .open
        }
        if shown {
            let uprightLongEnough = uprightSince.map { nowMs - $0 >= uprightExitMs } ?? false
            let unpluggedLongEnough = unpluggedAt.map { nowMs - $0 >= unplugExitMs } ?? false
            if uprightLongEnough || unpluggedLongEnough {
                uprightSince = nil
                unpluggedAt = nil
                return .close
            }
        }
        return .none
    }

    /// Standing on a long edge: gravity runs along the device's short axis (|gx| > 7) and not much through the
    /// screen (|gz| < 6, so flat on a table is not landscape). Standing on a short edge, the usual way a phone
    /// is held, gravity runs along the long axis (|gy| > 7): upright. Anything else (flat, propped far back,
    /// in between) is neither.
    public static func poseOf(gx: Double, gy: Double, gz: Double) -> Pose {
        if abs(gx) > 7 && abs(gz) < 6 { return .landscape }
        if abs(gy) > 7 { return .upright }
        return .other
    }

    /// Whether the last 1.5 s of gravity readings stayed within 0.5 m/s² on every axis. Only readings that cover the
    /// whole window count: a reading holds until the next one, so the window starts with the last reading at or
    /// before its beginning, and until there is one (the first 1.5 s after `clear()`) the phone is not still.
    public final class Stillness {
        private struct Reading {
            var timeMs: Int64
            var x: Double
            var y: Double
            var z: Double
        }

        private let windowMs: Int64
        private let tolerance: Double
        private var readings: [Reading] = []

        /// Since when the phone has been still: the first reading of the window in which `add` first said so, kept
        /// for as long as it stays still. Nil while it is not.
        public private(set) var stillSince: Int64?

        public init(windowMs: Int64 = 1_500, tolerance: Double = 0.5) {
            self.windowMs = windowMs
            self.tolerance = tolerance
        }

        /// Adds a reading and says whether the phone is still.
        public func add(nowMs: Int64, x: Double, y: Double, z: Double) -> Bool {
            readings.append(Reading(timeMs: nowMs, x: x, y: y, z: z))
            let start = nowMs - windowMs
            // Older than the window's first reading: the next one already holds at its start.
            while readings.count > 1 && readings[1].timeMs <= start { readings.removeFirst() }
            let first = readings[0]
            let still = first.timeMs <= start
                && Self.range(readings.map(\.x)) < tolerance
                && Self.range(readings.map(\.y)) < tolerance
                && Self.range(readings.map(\.z)) < tolerance
            stillSince = still ? (stillSince ?? first.timeMs) : nil
            return still
        }

        public func clear() {
            readings.removeAll()
            stillSince = nil
        }

        private static func range(_ values: [Double]) -> Double {
            (values.max() ?? 0) - (values.min() ?? 0)
        }
    }
}
