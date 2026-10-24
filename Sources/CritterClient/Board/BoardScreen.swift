import CoreGraphics
import Foundation

/// The screen as the board found it, or leaves it: brightness (0...1) and whether the screen is kept from
/// locking (`UIApplication.isIdleTimerDisabled`).
public struct ScreenState: Equatable, Sendable {
    public var brightness: Double
    public var idleTimerDisabled: Bool

    public init(brightness: Double, idleTimerDisabled: Bool) {
        self.brightness = brightness
        self.idleTimerDisabled = idleTimerDisabled
    }
}

/// What the board does to the screen (Android `BoardChrome.kt`, `BoardLook.kt`): dim after a quiet spell, shift the
/// picture so a static layout does not burn in, and the clock and date as the mockup reads them. All pure; the
/// board view applies the results.
public enum BoardScreen {
    /// How long the board waits, without a touch or a change, before it dims further.
    public static let idleDimAfter: TimeInterval = 15 * 60

    /// The shift of the whole layout is re-rolled this often (`shiftSeed(at:)` changes at that rate).
    public static let shiftEvery: TimeInterval = 3 * 60

    private static let burnInMax = 4

    /// The brightness the board shows: `base`, lowered to 60% once nothing has happened for 15 minutes. Idle counts
    /// from the later of `idleSince` (when what the board shows last changed) and `lastTouch`; with neither known
    /// it is not idle. Never below 0.01, so the board never goes black, nor above 1.
    public static func brightness(base: Double, idleSince: Date?, lastTouch: Date?, now: Date) -> Double {
        let lastActivity = [idleSince, lastTouch].compactMap { $0 }.max()
        // The clock lags a touch by up to a minute, so idle time can be negative: that is not idle either.
        let idle = lastActivity.map { now.timeIntervalSince($0) } ?? 0
        return min(max(idle >= idleDimAfter ? base * 0.6 : base, 0.01), 1)
    }

    /// A shift of the whole layout in whole points, each way within -4...4, the same for the same seed.
    public static func shift(seed: Int) -> CGSize {
        var generator = SplitMix64(seed: UInt64(bitPattern: Int64(seed)))
        let span = UInt64(2 * burnInMax + 1)
        let x = Int(generator.next() % span) - burnInMax
        let y = Int(generator.next() % span) - burnInMax
        return CGSize(width: x, height: y)
    }

    /// The seed for `shift(seed:)` at `date`: the same for every moment of one 3-minute span, a new one for the next.
    public static func shiftSeed(at date: Date) -> Int {
        Int((date.timeIntervalSince1970 / shiftEvery).rounded(.down))
    }

    private static let weekdays = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]

    /// "22:12".
    public static func clockText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let t = calendar(timeZone).dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", t.hour ?? 0, t.minute ?? 0)
    }

    /// "10 月 19 日 星期日".
    public static func dateText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let d = calendar(timeZone).dateComponents([.month, .day, .weekday], from: date)
        return "\(d.month ?? 1) 月 \(d.day ?? 1) 日 \(weekdays[((d.weekday ?? 1) - 1 + 7) % 7])"
    }

    /// Every way out of the board.
    public enum Exit: CaseIterable, Sendable {
        case closeButton
        /// The charger was pulled and stayed out for 10 seconds.
        case unplugged
        /// The phone stood upright for 3 seconds.
        case upright
        case background
        /// The app is about to be ended by the system.
        case terminated
    }

    /// The screen after leaving the board by `exit`: every way out brings back the brightness saved on the way in
    /// and lets the screen lock again.
    public static func restore(saved: ScreenState, on exit: Exit) -> ScreenState {
        ScreenState(brightness: saved.brightness, idleTimerDisabled: false)
    }

    /// The days are the Gregorian ones whatever calendar the phone uses.
    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

/// A small seeded generator: the same seed, the same sequence.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
