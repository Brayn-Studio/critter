import Foundation

/// What a device wants to be told about besides requests, which it always is.
public struct PushPrefs: Equatable, Sendable {
    public var notifyDone: Bool
    public var notifyError: Bool

    public init(notifyDone: Bool = false, notifyError: Bool = false) {
        self.notifyDone = notifyDone
        self.notifyError = notifyError
    }
}

/// What to do in response to a snapshot: the notifications to send and the ones to take down. A withdrawal is a
/// notification id (`PushPayload.notificationId`): a request's own id, or "<category>:<session id>".
/// Android `AlertPlan` without the buzz and the notification-shade bookkeeping.
public struct PushPlan: Sendable {
    /// New requests: one "waiting for you" notification each.
    public var post: [BridgePending]
    /// Requests that are gone.
    public var withdraw: [String]
    /// Sessions that just finished or failed, with the state they entered.
    public var results: [(BridgeSession, PetState)]
    /// Done/error notifications whose session left that state or ended.
    public var withdrawResults: [String]
    /// Sessions waiting for something the phone cannot answer (`ask` is terminal-only, so a VS Code session
    /// never has a request): "<名字> 等你确认（请在电脑上处理）".
    public var waitingNotices: [BridgeSession]
    /// Waiting notices whose session moved on, got a request, or ended.
    public var withdrawWaiting: [String]

    public init(
        post: [BridgePending] = [], withdraw: [String] = [],
        results: [(BridgeSession, PetState)] = [], withdrawResults: [String] = [],
        waitingNotices: [BridgeSession] = [], withdrawWaiting: [String] = []
    ) {
        self.post = post
        self.withdraw = withdraw
        self.results = results
        self.withdrawResults = withdrawResults
        self.waitingNotices = waitingNotices
        self.withdrawWaiting = withdrawWaiting
    }

    public var isEmpty: Bool {
        post.isEmpty && withdraw.isEmpty && results.isEmpty && withdrawResults.isEmpty
            && waitingNotices.isEmpty && withdrawWaiting.isEmpty
    }
}

/// Decides, snapshot by snapshot, what one device is pushed and what is taken back (Android `AlertPlanner` and
/// `AlertTracker`, without the floating pile and the buzz). One per device, fed every snapshot the Mac assembles
/// whether or not the phone is connected.
///
/// The first snapshot of a new or `reset()` tracker only records: the Mac has just started, push has just been
/// set up or the device has just registered, and what the snapshot shows is the past (spec 6.3; Android alerts
/// on it, the Mac does not). What it recorded still counts: a request in it is not pushed later, and is
/// withdrawn once it is answered.
///
/// A request is pushed the first time a snapshot lists it, and withdrawn when a snapshot no longer does.
///
/// Not thread-safe: one caller (the bridge queue).
public final class PushTracker {
    public var prefs: PushPrefs

    /// The snapshot before, nil until the first one.
    private var previous: SnapshotBody?

    /// Sessions with a waiting notice up (or due).
    private var noticed: Set<String> = []

    /// Sessions that had a request in their current waiting spell: answering it leaves the session "waiting"
    /// until the tool finishes, and that is not a reason to tell the user to go to the computer.
    private var hadRequest: Set<String> = []

    /// Session id -> the id of its done/error notification, for the sessions whose may be up.
    private var resulted: [String: String] = [:]

    public init(prefs: PushPrefs) {
        self.prefs = prefs
    }

    /// Forget everything: the next snapshot only records.
    public func reset() {
        previous = nil
        noticed = []
        hadRequest = []
        resulted = [:]
    }

    public func next(_ current: SnapshotBody) -> PushPlan {
        let waiting = updateWaiting(current)
        guard let previous else {
            // The past: remember it, say nothing.
            noticed = waiting.wantedIds
            self.previous = current
            return PushPlan()
        }

        // Requests. Everything a snapshot lists was pushed or recorded, so what the last one listed is what
        // the phone has.
        let before = Set(previous.pending.map(\.requestId))
        let after = Set(current.pending.map(\.requestId))
        let post = current.pending.filter { !before.contains($0.requestId) }
        let withdraw = previous.pending.map(\.requestId).filter { !after.contains($0) }

        // Waiting with nothing the phone can answer.
        let waitingNotices = waiting.wanted.filter { !noticed.contains($0.id) }
        let withdrawWaiting = previous.sessions.map(\.id)
            .filter { noticed.contains($0) && !waiting.wantedIds.contains($0) }
            .map { PushPayload.notificationId(category: .waitingElsewhere, requestId: nil, sessionId: $0) }
        noticed = waiting.wantedIds

        // Done / error: a state entered, not one a session arrives in.
        let previousState = Dictionary(previous.sessions.map { ($0.id, $0.state) }) { first, _ in first }
        let results: [(BridgeSession, PetState)] = current.sessions.compactMap { session in
            guard let was = previousState[session.id], was != session.state else { return nil }
            switch session.state {
            case .done where prefs.notifyDone, .error where prefs.notifyError: return (session, session.state)
            default: return nil
            }
        }

        // Taken down once the session leaves that state (looked at on the Mac, busy again) or ends; replaced
        // when it turns from one to the other.
        let finished = Set(current.sessions.filter { $0.state == .done || $0.state == .error }.map(\.id))
        var withdrawResults = previous.sessions.map(\.id)
            .filter { !finished.contains($0) }
            .compactMap { resulted.removeValue(forKey: $0) }
        for (session, state) in results {
            let id = PushPayload.notificationId(
                category: state == .done ? .done : .error, requestId: nil, sessionId: session.id
            )
            if let old = resulted.updateValue(id, forKey: session.id), old != id { withdrawResults.append(old) }
        }

        self.previous = current
        return PushPlan(
            post: post, withdraw: withdraw, results: results, withdrawResults: withdrawResults,
            waitingNotices: waitingNotices, withdrawWaiting: withdrawWaiting
        )
    }

    /// The sessions that wait with nothing the phone can answer, after taking this snapshot's requests into
    /// account.
    private func updateWaiting(_ current: SnapshotBody) -> (wanted: [BridgeSession], wantedIds: Set<String>) {
        let sessionIds = Set(current.sessions.map(\.id))
        let withRequest = Set(current.pending.map(\.sessionId))
        hadRequest.formIntersection(sessionIds)
        for session in current.sessions {
            if withRequest.contains(session.id) {
                hadRequest.insert(session.id)
            } else if session.state != .waiting {
                hadRequest.remove(session.id)
            }
        }
        let wanted = current.sessions.filter {
            $0.state == .waiting && !withRequest.contains($0.id) && !hadRequest.contains($0.id)
        }
        return (wanted, Set(wanted.map(\.id)))
    }
}
