/// Keeps the screen from locking while the phone waits for something the user does elsewhere -- the Mac's 「允许」 while
/// pairing, up to 120 s, long enough for the screen to lock and the pairing to fail -- and gives the setting back as it
/// was. Pure: the caller reads and writes `UIApplication.isIdleTimerDisabled`.
public struct ScreenAwakeHold: Equatable, Sendable {
    /// The setting before the hold; nil while not holding.
    private var saved: Bool?

    public init() {}

    public var isHolding: Bool { saved != nil }

    /// Starts (or goes on) holding; the value to set: on. The setting found the first time is the one given back.
    public mutating func hold(current: Bool) -> Bool {
        if saved == nil { saved = current }
        return true
    }

    /// Stops holding; the value to give back, or nil when it was not holding.
    public mutating func release() -> Bool? {
        defer { saved = nil }
        return saved
    }
}
