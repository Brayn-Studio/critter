import CritterKit

/// What the app does to its own Live Activity now (`LocalActivity.step`).
public enum LocalActivityStep: Equatable, Sendable {
    case none
    /// Start one showing this (pushed by the Mac from then on, once its token is registered).
    case start(LiveActivityContent)
    /// Show this in the running one.
    case update(LiveActivityContent)
    /// End every one, at once: the switch is off.
    case endAll
}

/// One of the app's running Live Activities, for `LocalActivity.keeper`: its id, and when the app first saw it
/// (milliseconds since the epoch; the ones there at launch all get the launch time).
public struct RunningActivity: Equatable, Sendable {
    public var id: String
    public var seenAt: Int64

    public init(id: String, seenAt: Int64) {
        self.id = id
        self.seenAt = seenAt
    }
}

/// The app's part in the Live Activity (spec §8.5, §9). The Mac pushes it; the app only:
/// - starts one when it is in front, connected (a snapshot from now, and a Mac to give the activity's token to), the
///   switch is on and there are sessions, but none is running;
/// - updates it with the content of each new snapshot while in front and connected, when it shows something else (the
///   time it was made aside);
/// - ends it at once when the switch is turned off, wherever it is.
///
/// In the background it never touches it: the Mac's pushes do it all. The content is the Mac's rule
/// (`LiveActivityContent(snapshot:updatedAt:)`), so the two never disagree. Pure: `LiveActivityManager` in the app
/// does what it says.
public enum LocalActivity {
    /// The content the app shows for `snapshot`, made at `now` (milliseconds since the epoch).
    public static func content(_ snapshot: SnapshotBody, now: Int64) -> LiveActivityContent {
        LiveActivityContent(snapshot: snapshot, updatedAt: now)
    }

    /// - Parameters:
    ///   - enabled: the switch in the settings (and the system lets the app have Live Activities).
    ///   - inFront: the app is active.
    ///   - live: connected to the Mac, with its snapshot.
    ///   - shown: what the running activity shows; nil when none is running.
    public static func step(
        enabled: Bool, inFront: Bool, live: Bool, snapshot: SnapshotBody?, shown: LiveActivityContent?, now: Int64
    ) -> LocalActivityStep {
        guard enabled else { return shown == nil ? .none : .endAll }
        guard inFront, live, let snapshot else { return .none }
        let content = content(snapshot, now: now)
        guard let shown else { return content.total > 0 ? .start(content) : .none }
        return same(shown, content) ? .none : .update(content)
    }

    /// Which of the running activities the app keeps when there are more than one (the Mac's push-to-start next to
    /// the app's own start); the others are ended. The one the registration names (the Mac pushes to it); before any is
    /// named, the app's own (`own`, the one it started); otherwise the newest -- the one the app saw last, and among
    /// those seen at the same moment (at launch) the smallest id. Nil when none runs.
    public static func keeper(running: [RunningActivity], named: String?, own: String?) -> String? {
        let ids = Set(running.map(\.id))
        if let named, ids.contains(named) { return named }
        if let own, ids.contains(own) { return own }
        return running.sorted { $0.seenAt != $1.seenAt ? $0.seenAt > $1.seenAt : $0.id < $1.id }.first?.id
    }

    /// Whether two contents show the same thing: all but the time they were made.
    public static func same(_ a: LiveActivityContent, _ b: LiveActivityContent) -> Bool {
        var a = a
        a.updatedAt = b.updatedAt
        return a == b
    }
}
