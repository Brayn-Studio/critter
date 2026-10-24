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
        /// The app stopped being in front without going to the background (Control Center, the app switcher, a call
        /// coming in); it takes the screen again once it is active.
        case inactive
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

/// An automatic close of the board (unplugged for 10 s, upright for 3 s) while an answer card is open over it waits for
/// the card: the card, and what is typed in it, would go with the board. Closing by hand does not wait. Once the card
/// closes, the held close is done if a reason for it still holds (the charger still out, the phone still upright), and
/// called off if none does (plugged in again and lying in landscape: the board stays).
public struct BoardCloseHold: Sendable {
    /// What closing the card does about a held close.
    public enum Release: Equatable, Sendable {
        /// Nothing was held.
        case none
        /// Close the board now, for this reason.
        case close(BoardScreen.Exit)
        /// A close was held, and no reason for it holds any more: the board stays.
        case calledOff
    }

    /// Whether an answer card is open over the board.
    public private(set) var cardIsOpen = false
    /// The close waiting for the card, if any.
    public private(set) var held: BoardScreen.Exit?

    public init() {}

    /// The automatic opening wants the board closed for `reason`: true to close it now, false when it waits for the
    /// card.
    public mutating func close(_ reason: BoardScreen.Exit) -> Bool {
        guard cardIsOpen else { return true }
        held = reason
        return false
    }

    /// The card opened (`open`) or closed. `reasonNow`: why the board should still close now (`.unplugged`,
    /// `.upright`), nil if neither holds any more.
    public mutating func cardOpen(_ open: Bool, reasonNow: BoardScreen.Exit?) -> Release {
        guard open != cardIsOpen else { return .none }
        cardIsOpen = open
        guard !open, held != nil else { return .none }
        held = nil
        return reasonNow.map(Release.close) ?? .calledOff
    }

    /// The board went (by hand, or any other way): nothing is held for it any more.
    public mutating func boardGone() {
        held = nil
    }
}
