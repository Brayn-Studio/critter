import CritterKit
import Foundation

/// Where a tapped notification asked the app to go (spec §8.4): a request's answer card or a session's details, with
/// the pairing it came under (`StoredPairing.deviceId`): the Mac that pushed it is the one paired then.
public struct NotificationTarget: Equatable, Sendable {
    public enum Place: Equatable, Sendable {
        case request(String)
        case session(String)
    }

    public var place: Place
    /// The pairing when it was tapped; nil if there was none.
    public var pairing: String?

    public init(_ place: Place, pairing: String?) {
        self.place = place
        self.pairing = pairing
    }

    /// What the home screen does with it now.
    public enum Decision: Equatable, Sendable {
        /// The request's card, by its id.
        case openRequest(String)
        /// The session: its details, or its request's card.
        case openSession(BridgeSession)
        /// Not yet: the snapshot may be out of date.
        case wait
        /// Nothing to open: let it go.
        case drop
    }

    /// Whether it came under `pairing`: one made since (pairing again, or unpaired) belongs to another Mac, which
    /// knows nothing of the request or the session, even under the same id.
    public func belongs(to pairing: String?) -> Bool {
        pairing != nil && pairing == self.pairing
    }

    /// What to do with it under `pairing` (the current one), with `snapshot` as the screen has it:
    /// - from another pairing: dropped;
    /// - a request: its card at once (the card waits for a live snapshot itself before it says the request is gone);
    /// - a session the snapshot has: opened;
    /// - a session it lacks: it waits while the snapshot may be out of date (none yet, or the cached one at a cold
    ///   launch) and the wait has not run out (`waitedOut`, as long as the sheets wait for a live snapshot); a live
    ///   snapshot without it, or the end of the wait, drops it (the home screen is the place to look).
    public func decision(pairing current: String?, snapshot: SnapshotBody?, isLive: Bool, waitedOut: Bool) -> Decision {
        guard belongs(to: current) else { return .drop }
        switch place {
        case .request(let requestId):
            return .openRequest(requestId)
        case .session(let sessionId):
            if let session = snapshot?.sessions.first(where: { $0.id == sessionId }) { return .openSession(session) }
            return isLive || waitedOut ? .drop : .wait
        }
    }
}
