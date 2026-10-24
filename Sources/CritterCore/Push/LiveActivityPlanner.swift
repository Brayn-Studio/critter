import Foundation

/// What the Mac does to a phone's Live Activity. Times are milliseconds since the epoch.
public enum LiveActivityAction: Equatable, Sendable {
    /// Push-to-start a new activity showing this.
    case start(LiveActivityContent)
    /// Update the running one. `priority` is the push's: 10 now, 5 when convenient.
    case update(LiveActivityContent, priority: Int)
    /// End the running one; it leaves the screen at `dismissAt`.
    case end(dismissAt: Int64)
}

/// When to start, update and end one device's Live Activity (spec 6.6). Pure: the caller passes the time and what
/// the phone has told it, sends what comes back, and sets a one-shot timer for `nextDeadline()` -- when it
/// fires, calls `next` again with the current content. One per device; not thread-safe (the bridge queue).
///
/// The planner assumes what it returns is sent. An activity the Mac never started (the app opens one in the
/// foreground) is picked up from the token the phone reports.
public final class LiveActivityPlanner {
    /// An ordinary change is sent at most this often.
    public static let throttle: Int64 = 10 * 1000
    /// While there are sessions and an activity whose token the phone reported, a content that has not changed is sent
    /// again (low priority) this long after the last push, as it was: only the push's stale date and timestamp move on,
    /// so an activity that is quiet but true does not turn grey ("可能不是最新的" after 15 minutes; spec §8.5, §9).
    public static let refresh: Int64 = 12 * 60 * 1000
    /// The activity ends this long after the last session does.
    public static let endAfterEmpty: Int64 = 5 * 60 * 1000
    /// The system ends an activity after 8 hours; the Mac replaces it at 7.5.
    public static let maxAge: Int64 = (7 * 60 + 30) * 60 * 1000
    /// An activity is not started again sooner than this after the last start, so one the user swiped away does
    /// not come straight back, and a start whose token is slow does not turn into two.
    public static let minStartInterval: Int64 = 10 * 60 * 1000
    /// A start whose token never came holds further starts off this long: by then the system has ended it.
    public static let unconfirmedStartLimit: Int64 = 8 * 60 * 60 * 1000

    /// When the Mac push-to-started an activity whose token has not arrived yet; nil when none. No new start
    /// while it is set (for up to `unconfirmedStartLimit`): the activity may well be on the screen. The caller
    /// keeps it across restarts (`devices.json`) and gives it back to `init`.
    public private(set) var unconfirmedStartAt: Int64?

    /// What the phone was last sent to show.
    private var lastSent: LiveActivityContent?
    private var lastUpdateAt: Int64?
    /// A change is waiting for the end of the throttle period.
    private var changeWaiting = false
    /// Since when the Mac believes an activity exists: from its start, or from first seeing its token. Nil when
    /// none does. An activity started by the Mac has no token until the phone reports one.
    private var activitySince: Int64?
    private var lastStartAt: Int64?
    /// The activity token the phone reports, and one the Mac ended (the phone may go on reporting it for a while).
    private var trackedToken: String?
    private var endedToken: String?
    /// Since when there have been no sessions.
    private var emptySince: Int64?
    /// The activity is 7.5 hours old but could not be replaced (no start token): that deadline is not reported
    /// again, or the caller's timer would fire on it over and over. It is still replaced once a start token comes.
    private var ageWaitsForStartToken = false

    /// - Parameter unconfirmedStartAt: what an earlier planner for this device left in `unconfirmedStartAt`.
    public init(unconfirmedStartAt: Int64? = nil) {
        self.unconfirmedStartAt = unconfirmedStartAt
        lastStartAt = unconfirmedStartAt
    }

    /// The content to show for `snapshot`: CritterKit's `LiveActivityContent(snapshot:updatedAt:)`, the rule the
    /// phone uses for the activity it updates itself as well.
    public func content(from snapshot: SnapshotBody, updatedAt: Int64 = 0) -> LiveActivityContent {
        LiveActivityContent(snapshot: snapshot, updatedAt: updatedAt)
    }

    /// What to send now. `content` is the current content (its `updatedAt` is replaced by `now` in what is sent);
    /// the rest is what the phone's registration says.
    public func next(
        content: LiveActivityContent, now: Int64, activityEnabled: Bool, hasStartToken: Bool, activityToken: String?
    ) -> [LiveActivityAction] {
        // A token the Mac ended stands for no activity, also when the phone reports it again after a while.
        if let activityToken, activityToken != endedToken { endedToken = nil }
        let token = activityToken == endedToken ? nil : activityToken
        observe(token, now: now)
        // A start whose token never came holds nothing off after 8 hours, whether or not a start follows now: its
        // deadline is not due again.
        if let unconfirmed = unconfirmedStartAt, now - unconfirmed >= Self.unconfirmedStartLimit { unconfirmedStartAt = nil }

        guard activityEnabled else {
            // The phone has no Live Activity now: no start of the Mac's is waiting for its token either.
            unconfirmedStartAt = nil
            defer { forget() }
            guard let token else { return [] }
            endedToken = token
            return [.end(dismissAt: now)]
        }

        if content.total == 0 {
            if emptySince == nil { emptySince = now }
        } else {
            emptySince = nil
        }

        var actions: [LiveActivityAction] = []

        // Nearing the system's limit: end this one, and start another below.
        if let since = activitySince, now - since >= Self.maxAge {
            if let token {
                if hasStartToken {
                    actions.append(.end(dismissAt: now))
                    endedToken = token
                    forget()
                } else {
                    ageWaitsForStartToken = true
                }
            } else {
                forget()  // a start the phone never reported on
            }
        }

        // No sessions for a while.
        if let emptySince, now - emptySince >= Self.endAfterEmpty {
            if activitySince != nil {
                if let token {
                    actions.append(.end(dismissAt: now))
                    endedToken = token
                }
                forget()
            }
            return actions
        }

        guard activitySince != nil else {
            guard content.total > 0, hasStartToken, canStart(at: now) else { return actions }
            let started = stamped(content, now)
            lastSent = started
            lastUpdateAt = now
            lastStartAt = now
            unconfirmedStartAt = now
            activitySince = now
            ageWaitsForStartToken = false
            changeWaiting = false
            actions.append(.start(started))
            return actions
        }

        // The activity exists, or its token is on its way: only a token lets the Mac update it.
        guard token != nil else { return actions }
        guard let sent = lastSent else {
            send(content, priority: 5, now: now, into: &actions)  // seen for the first time: say what is true now
            return actions
        }
        guard !same(sent, content) else {
            changeWaiting = false
            // Quiet but true: the same content again now and then, so that its stale date moves on.
            if content.total > 0, let last = lastUpdateAt, now - last >= Self.refresh {
                lastUpdateAt = now
                actions.append(.update(sent, priority: 5))
            }
            return actions
        }
        let moreWaiting = waiting(content) > waiting(sent)
        if moreWaiting {
            send(content, priority: 10, now: now, into: &actions)
        } else if let last = lastUpdateAt, now - last < Self.throttle {
            changeWaiting = true
        } else {
            send(content, priority: 5, now: now, into: &actions)
        }
        return actions
    }

    /// APNs refused the last push-to-start (its token is gone): no activity came of it, so it holds nothing off.
    public func startWasRefused() {
        guard unconfirmedStartAt != nil else { return }
        forget()
        unconfirmedStartAt = nil
        lastStartAt = nil
    }

    /// The last push-to-start went nowhere for another reason than its token: APNs refused the setup or the push,
    /// or there was no network. No activity is waiting for its token, so it holds nothing off for 8 hours; the 10
    /// minutes between starts still count (the push may have got through before the network failed).
    public func startNotDelivered() {
        guard unconfirmedStartAt != nil else { return }
        forget()
        unconfirmedStartAt = nil
    }

    /// When `next` next has something to do without a new snapshot: the end of the throttle period, the refresh of
    /// a quiet activity, the end of the empty wait, the 7.5 hours, or the 8 hours after which a start whose token never
    /// came no longer holds the next one off (the 7.5 hours forget the activity, not the start). Nil if none.
    public func nextDeadline() -> Int64? {
        var deadlines: [Int64] = []
        if changeWaiting, let last = lastUpdateAt { deadlines.append(last + Self.throttle) }
        if activitySince != nil, trackedToken != nil, emptySince == nil, let last = lastUpdateAt,
           (lastSent?.total ?? 0) > 0 {
            deadlines.append(last + Self.refresh)
        }
        if activitySince != nil, let emptySince { deadlines.append(emptySince + Self.endAfterEmpty) }
        if let since = activitySince, !ageWaitsForStartToken { deadlines.append(since + Self.maxAge) }
        if let unconfirmed = unconfirmedStartAt { deadlines.append(unconfirmed + Self.unconfirmedStartLimit) }
        return deadlines.min()
    }

    // MARK: -

    /// Takes in the token the phone reports.
    private func observe(_ token: String?, now: Int64) {
        // Any activity's token: the start the Mac made has come up, or the app has one of its own.
        if token != nil { unconfirmedStartAt = nil }
        guard token != trackedToken else { return }
        switch (trackedToken, token) {
        case (nil, nil):
            break
        case (nil, _?):
            // An activity's token arrives: the one the Mac started, or one it has not seen.
            if activitySince == nil {
                activitySince = now
                ageWaitsForStartToken = false
            }
        case (_?, nil):
            // It was running and is gone (swiped away, or ended by the system). A start soon after the last is held off.
            activitySince = nil
            ageWaitsForStartToken = false
            lastSent = nil
            changeWaiting = false
        case (_?, _?):
            // Another activity in its place: what it shows is unknown.
            activitySince = now
            ageWaitsForStartToken = false
            lastSent = nil
            changeWaiting = false
        }
        trackedToken = token
    }

    private func send(_ content: LiveActivityContent, priority: Int, now: Int64, into actions: inout [LiveActivityAction]) {
        let update = stamped(content, now)
        lastSent = update
        lastUpdateAt = now
        changeWaiting = false
        actions.append(.update(update, priority: priority))
    }

    /// `next` has let go of a start whose 8 hours are over.
    private func canStart(at now: Int64) -> Bool {
        guard unconfirmedStartAt == nil else { return false }
        return lastStartAt.map { now - $0 >= Self.minStartInterval } ?? true
    }

    /// No activity known. The last start and one still waiting for its token are kept: they hold the next
    /// start off.
    private func forget() {
        lastSent = nil
        lastUpdateAt = nil
        changeWaiting = false
        activitySince = nil
        ageWaitsForStartToken = false
        trackedToken = nil
        emptySince = nil
    }

    private func stamped(_ content: LiveActivityContent, _ now: Int64) -> LiveActivityContent {
        var copy = content
        copy.updatedAt = now
        return copy
    }

    /// Whether the two show the same thing: all but the time they were made.
    private func same(_ a: LiveActivityContent, _ b: LiveActivityContent) -> Bool {
        stamped(a, 0) == stamped(b, 0)
    }

    private func waiting(_ content: LiveActivityContent) -> Int {
        content.counts.first { $0.state == .waiting }?.count ?? 0
    }
}
