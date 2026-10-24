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

    /// Whether two contents show the same thing: all but the time they were made.
    public static func same(_ a: LiveActivityContent, _ b: LiveActivityContent) -> Bool {
        var a = a
        a.updatedAt = b.updatedAt
        return a == b
    }
}
