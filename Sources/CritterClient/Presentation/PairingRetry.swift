/// Whether a failed pairing is tried again by itself when the app is active again: the 本地网络 prompt answered (it
/// makes the app inactive, and the connection fails while it is up, or just before it shows), or the user back from
/// turning something on (「允许手机连接」 on the Mac). Only an unreachable Mac, only once per target (scanned or typed:
/// the same code is not tried again and again), and only while the attempt, or its failure page, is still the
/// screen's: not once the user has left that page or started another attempt.
///
/// The pairing screen's bookkeeping, told when an attempt starts, fails and ends, and how `scenePhase` changes; it says
/// which target to try again, and when. Pure.
public struct PairingRetry: Equatable, Sendable {
    /// Where the last attempt is.
    private enum Stage: Equatable, Sendable {
        /// None, or it is over (paired, cancelled, its failure page left).
        case none
        case underWay
        /// Its failure is on the page.
        case failed(PairFailure)
    }

    private var target: PairingTarget?
    private var stage = Stage.none
    /// The app was not active during the attempt, or since it failed.
    private var wasInactive = false
    /// `target` was tried again by itself already.
    private var retried = false
    private var active = true

    public init() {}

    /// Whether a failed pairing is tried again by itself when the app is active again (the 本地网络 prompt answered, or
    /// the user back from turning something on). Pure.
    public static func retriesWhenActive(failure: PairFailure, wasInactive: Bool, alreadyRetried: Bool) -> Bool {
        failure == .unreachable && wasInactive && !alreadyRetried
    }

    /// An attempt with `target` starts: scanned, typed, from a link, or tried again. Another target than the last may
    /// be tried again by itself once more. The app not active before now does not count; still not active, it does.
    public mutating func started(_ target: PairingTarget) {
        if target != self.target { retried = false }
        self.target = target
        stage = .underWay
        wasInactive = !active
    }

    /// The attempt under way failed. The target to try again now, if the app was not active during it and is again
    /// already (the prompt answered before the attempt gave up).
    public mutating func failed(_ failure: PairFailure) -> PairingTarget? {
        guard stage == .underWay else { return nil }
        stage = .failed(failure)
        return active ? retry() : nil
    }

    /// The attempt, or its failure page, is gone: paired, cancelled, or the page left. Nothing is tried again.
    public mutating func ended() {
        stage = .none
    }

    /// The app is active, or not (`scenePhase`). Back to active, the target to try again, if any.
    public mutating func sceneChanged(active: Bool) -> PairingTarget? {
        self.active = active
        // Before an attempt it does not count: `started` sets it afresh.
        if !active { wasInactive = true }
        return active ? retry() : nil
    }

    /// The failed attempt's target, marked tried again, if the rule says so.
    private mutating func retry() -> PairingTarget? {
        guard case .failed(let failure) = stage, let target,
              Self.retriesWhenActive(failure: failure, wasInactive: wasInactive, alreadyRetried: retried)
        else { return nil }
        retried = true
        return target
    }
}
