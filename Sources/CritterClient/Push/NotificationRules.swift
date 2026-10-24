import CritterKit

/// A notification on the phone, as `UNUserNotificationCenter` lists the delivered ones.
public struct DeliveredNotification: Equatable, Sendable {
    /// Its id: the push's `apns-collapse-id` (`PushPayload.notificationId`), or the system's own for a push without
    /// one (the test notification).
    public var id: String
    /// `UNNotificationContent.categoryIdentifier`: a `PushCategory`'s raw value, or nil (a result shown in a
    /// request's place has none).
    public var category: String?

    public init(id: String, category: String?) {
        self.id = id
        self.category = category
    }
}

/// Which pushes the app shows as a banner, and which notifications it takes down (spec §8.7).
public enum NotificationRules {
    /// Whether a notification that arrives is shown as a banner. Not when the app is in the foreground and the
    /// request is in the snapshot already: it is on the screen, so a light tap is enough. `requestId` nil: not about
    /// a request (done, error, 请在电脑上处理, the test) -- always shown.
    public static func showBanner(requestId: String?, snapshot: SnapshotBody?, isForeground: Bool) -> Bool {
        guard isForeground, let requestId, let snapshot else { return true }
        return !snapshot.pending.contains { $0.requestId == requestId }
    }

    /// The delivered notifications to take down when the app comes to the foreground and a snapshot has come: the
    /// Mac's withdrawals are background pushes, which may never arrive. By the ids' rule (`PushPayload.notificationId`):
    /// a request's notification (its id is the request's) goes when the snapshot no longer lists the request; a
    /// session's (`done:`, `error:`, `waitingElsewhere:` and the session id) when the session is no longer in that
    /// state, or gone. The test notification is not the snapshot's business.
    public static func staleNotificationIds(delivered: [DeliveredNotification], snapshot: SnapshotBody) -> [String] {
        let pending = Set(snapshot.pending.map(\.requestId))
        let states = Dictionary(snapshot.sessions.map { ($0.id, $0.state) }) { first, _ in first }
        return delivered.filter { notice in
            if notice.category == PushCategory.test.rawValue { return false }
            if let (state, sessionId) = sessionNotice(notice.id) { return states[sessionId] != state }
            return !pending.contains(notice.id)
        }.map(\.id)
    }

    /// The state a session's notification is about, and the session: from an id `<category>:<session id>`.
    private static func sessionNotice(_ id: String) -> (PetState, String)? {
        let kinds: [(PushCategory, PetState)] = [(.done, .done), (.error, .error), (.waitingElsewhere, .waiting)]
        for (category, state) in kinds {
            let prefix = category.rawValue + ":"
            if id.hasPrefix(prefix) { return (state, String(id.dropFirst(prefix.count))) }
        }
        return nil
    }
}
