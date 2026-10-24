import Foundation

/// What a notification is about. The raw values are the iOS notification category ids.
public enum PushCategory: String, Codable, Sendable, CaseIterable {
    case permission
    /// A permission request that cannot be denied with a reason (Codex).
    case permissionNoReason
    case question
    case plan
    /// A session is waiting but the phone cannot answer it: "请在电脑上处理".
    case waitingElsewhere
    case done
    case error
    case test
}

/// A push read back by the phone and its notification service extension.
public enum ParsedPush: Equatable, Sendable {
    public struct Alert: Equatable, Sendable {
        public var category: PushCategory
        /// Absent for notifications that are not about a request (`done`, `error`, ...).
        public var requestId: String?
        public var sessionId: String
        /// `PushCrypto`'s sealed text.
        public var sealed: String

        public init(category: PushCategory, requestId: String?, sessionId: String, sealed: String) {
            self.category = category
            self.requestId = requestId
            self.sessionId = sessionId
            self.sealed = sealed
        }

        public var notificationId: String {
            PushPayload.notificationId(category: category, requestId: requestId, sessionId: sessionId)
        }
    }

    case alert(Alert)
    /// A background push asking the phone to take these notifications down.
    case withdraw(ids: [String])
}

/// The JSON object APNs delivers. Plain text in it is only "Critter / 有会话需要你"; everything
/// the notification says is in `c`, sealed with `PushCrypto`. The other custom keys are ids and
/// the category: `r` request id, `s` session id, `k` category, `w` notification ids to withdraw.
public enum PushPayload {
    public static let title = "Critter"
    public static let body = "有会话需要你"

    /// The id a notification goes by (also its `apns-collapse-id`, so a withdrawal can name it):
    /// a request's own id, or "<category>:<session id>".
    public static func notificationId(category: PushCategory, requestId: String?, sessionId: String) -> String {
        requestId ?? "\(category.rawValue):\(sessionId)"
    }

    public static func alert(
        category: PushCategory, requestId: String?, sessionId: String, sealed: String, timeSensitive: Bool
    ) -> [String: Any] {
        var aps: [String: Any] = [
            "alert": ["title": title, "body": body],
            "mutable-content": 1,
            "category": category.rawValue,
            "thread-id": sessionId,
            "sound": "default",
        ]
        if timeSensitive { aps["interruption-level"] = "time-sensitive" }
        var payload: [String: Any] = ["aps": aps, "c": sealed, "s": sessionId, "k": category.rawValue]
        if let requestId { payload["r"] = requestId }
        return payload
    }

    public static func withdraw(ids: [String]) -> [String: Any] {
        ["aps": ["content-available": 1], "w": ids]
    }

    /// What `alert` or `withdraw` wrote, or nil for any other push.
    public static func parse(_ userInfo: [AnyHashable: Any]) -> ParsedPush? {
        if let ids = userInfo["w"] as? [String] {
            return .withdraw(ids: ids)
        }
        guard let sealed = userInfo["c"] as? String, let sessionId = userInfo["s"] as? String,
              let category = (userInfo["k"] as? String).flatMap(PushCategory.init(rawValue:))
        else { return nil }
        return .alert(ParsedPush.Alert(
            category: category, requestId: userInfo["r"] as? String, sessionId: sessionId, sealed: sealed
        ))
    }
}
