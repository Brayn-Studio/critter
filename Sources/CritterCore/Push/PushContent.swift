import Foundation

/// The `apns-push-type` of a message; the raw value is the header's.
public enum APNsPushType: String, Sendable {
    case alert
    case background
    case liveActivity = "liveactivity"
}

/// One push ready for APNs: the headers that depend on what it is, and the JSON body. The device token,
/// environment and authorization are `APNsRequest`'s.
public struct APNsMessage: Equatable, Sendable {
    public var pushType: APNsPushType
    /// `apns-priority`: 10 now, 5 when convenient. Background pushes must be 5.
    public var priority: Int
    /// `apns-collapse-id`, at most 64 bytes: a newer push with the same id replaces the older.
    public var collapseId: String?
    /// `apns-expiration`, seconds since the Unix epoch: APNs stops trying to deliver after it.
    public var expiration: Int64?
    public var payload: Data

    public init(pushType: APNsPushType, priority: Int, collapseId: String? = nil, expiration: Int64? = nil, payload: Data) {
        self.pushType = pushType
        self.priority = priority
        self.collapseId = collapseId
        self.expiration = expiration
        self.payload = payload
    }
}

public enum PushContentError: Error, Equatable {
    /// Not even a push with its text cut to nothing fits 4 KB.
    case tooLarge
}

/// Turns what the Mac knows into pushes. The words are sealed with the phone's key (`PushCrypto`): the plain
/// payload holds only ids, the category and the fixed "Critter / 有会话需要你". Pure.
public enum PushContent {
    /// APNs refuses a payload over this.
    public static let maxPayloadBytes = 4096
    /// A title is cut to this many characters, ellipsis included.
    public static let maxTitleCharacters = 60
    /// APNs refuses a longer `apns-collapse-id`.
    public static let maxCollapseIdBytes = 64
    /// A Live Activity update older than this shows as possibly out of date.
    public static let staleSeconds: Int64 = 15 * 60

    private static let ellipsis = "…"

    // MARK: - Notifications

    /// A request waiting for an answer. Titled "<名字> 想 …", subtitled with where the session runs, the body is
    /// the command or path (a permission) or the folder; Android `Alerts.post`.
    public static func request(_ request: BridgePending, session: BridgeSession?, key: String) throws -> APNsMessage {
        let category: PushCategory
        switch request.kind {
        case .permission: category = NotificationText.acceptsDenyMessage(request.input) ? .permission : .permissionNoReason
        case .question: category = .question
        case .plan: category = .plan
        }
        let text = PushText(
            title: NotificationText.title(request, session: session),
            subtitle: session.map(NotificationText.place) ?? "",
            body: NotificationText.requestBody(request, session: session) ?? ""
        )
        var message = try sealed(
            text, category: category, requestId: request.requestId, sessionId: request.sessionId,
            timeSensitive: true, key: key
        )
        // The hook gives up at `expiresAt`; APNs should too.
        message.expiration = request.expiresAt.map { $0 / 1000 }
        return message
    }

    /// "<名字> 等你确认（请在电脑上处理）": a session waits for something the phone cannot answer.
    public static func waitingNotice(_ session: BridgeSession, key: String) throws -> APNsMessage {
        let text = PushText(
            title: NotificationText.waitingNoticeTitle(session), subtitle: NotificationText.place(session),
            body: NotificationText.waitingNoticeBody(session)
        )
        return try sealed(
            text, category: .waitingElsewhere, requestId: nil, sessionId: session.id, timeSensitive: true, key: key
        )
    }

    /// "<名字> 做完了" or "<名字> 出错".
    public static func result(_ session: BridgeSession, state: PetState, key: String) throws -> APNsMessage {
        let text = PushText(
            title: NotificationText.resultTitle(session, state: state), subtitle: NotificationText.place(session),
            body: NotificationText.resultBody(session)
        )
        return try sealed(
            text, category: state == .error ? .error : .done, requestId: nil, sessionId: session.id,
            timeSensitive: false, key: key
        )
    }

    /// The settings' "发送测试通知".
    public static func test(key: String) throws -> APNsMessage {
        let text = PushText(title: "Critter 推送测试", subtitle: "", body: "能看到这条，说明推送通了")
        var message = try sealed(text, category: .test, requestId: nil, sessionId: "test", timeSensitive: false, key: key)
        message.collapseId = nil
        return message
    }

    /// Silent pushes asking the phone to take these notifications down (`PushTracker`'s withdrawals). Usually
    /// one; split when the ids would not fit 4 KB together. None for no ids.
    public static func withdraw(ids: [String]) -> [APNsMessage] {
        var messages: [APNsMessage] = []
        var chunk: [String] = []
        for id in ids {
            let together = (try? size(PushPayload.withdraw(ids: chunk + [id]))) ?? Int.max
            if !chunk.isEmpty, together > maxPayloadBytes {
                messages.append(withdrawal(chunk))
                chunk = []
            }
            chunk.append(id)
        }
        if !chunk.isEmpty { messages.append(withdrawal(chunk)) }
        return messages
    }

    private static func withdrawal(_ ids: [String]) -> APNsMessage {
        let payload = (try? serialize(PushPayload.withdraw(ids: ids))) ?? Data()
        return APNsMessage(pushType: .background, priority: 5, payload: payload)
    }

    // MARK: - Live Activity

    /// A Live Activity push. Times are milliseconds since the epoch; the payload has them in seconds. The
    /// content is numbers, skin names and states only (the system renders it as it comes), so nothing needs
    /// sealing. An `end` carries an empty content: the system decodes a content state for every event.
    /// - Parameter timestamp: `aps.timestamp` in seconds, when not `now`'s: the system drops an update whose
    ///   timestamp is not later than the last one's, so the caller keeps them increasing.
    public static func liveActivity(_ action: LiveActivityAction, now: Int64, timestamp: Int64? = nil) throws -> APNsMessage {
        let seconds = now / 1000
        var aps: [String: Any] = ["timestamp": timestamp ?? seconds]
        let priority: Int
        switch action {
        case .start(let content):
            aps["event"] = "start"
            aps["content-state"] = try state(content)
            aps["stale-date"] = seconds + staleSeconds
            aps["attributes-type"] = LiveActivityContent.attributesName
            aps["attributes"] = [String: Any]()
            aps["alert"] = ["title": PushPayload.title, "body": PushPayload.body]
            priority = 10
        case .update(let content, let wanted):
            aps["event"] = "update"
            aps["content-state"] = try state(content)
            aps["stale-date"] = seconds + staleSeconds
            priority = wanted >= 10 ? 10 : 5
        case .end(let dismissAt):
            aps["event"] = "end"
            aps["content-state"] = try state(LiveActivityContent(
                counts: [], lead: nil, back: [], total: 0, fiveHour: nil, sevenDay: nil, updatedAt: now
            ))
            aps["dismissal-date"] = dismissAt / 1000
            priority = 10
        }
        return APNsMessage(pushType: .liveActivity, priority: priority, payload: try serialize(["aps": aps]))
    }

    private static func state(_ content: LiveActivityContent) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(content))
    }

    // MARK: - Sealing and fitting

    /// An alert push for `text`, sealed, within 4 KB: a title over `maxTitleCharacters` is cut, and a payload
    /// still too big loses the end of its body first and then of its subtitle (on a character boundary, with an
    /// ellipsis). A push for a session or request gets `PushPayload.notificationId` as its collapse id.
    private static func sealed(
        _ text: PushText, category: PushCategory, requestId: String?, sessionId: String, timeSensitive: Bool, key: String
    ) throws -> APNsMessage {
        func payload(_ text: PushText) throws -> Data {
            try serialize(PushPayload.alert(
                category: category, requestId: requestId, sessionId: sessionId,
                sealed: PushCrypto.seal(text, key: key, category: category, requestId: requestId, sessionId: sessionId),
                timeSensitive: timeSensitive
            ))
        }
        func fits(_ text: PushText) throws -> Bool { try payload(text).count <= maxPayloadBytes }

        var text = text
        text.title = cut(text.title, to: maxTitleCharacters)
        if try !fits(text) {
            let whole = text
            if let body = try longestCut(of: whole.body, fits: { try fits(with(whole, body: $0)) }) {
                text.body = body
            } else {
                text.body = whole.body.isEmpty ? "" : ellipsis
                let bodyless = text
                guard let subtitle = try longestCut(of: bodyless.subtitle, fits: { try fits(with(bodyless, subtitle: $0)) })
                else { throw PushContentError.tooLarge }
                text.subtitle = subtitle
            }
        }
        let id = PushPayload.notificationId(category: category, requestId: requestId, sessionId: sessionId)
        return APNsMessage(
            pushType: .alert, priority: 10, collapseId: id.utf8.count <= maxCollapseIdBytes ? id : nil,
            payload: try payload(text)
        )
    }

    private static func with(_ text: PushText, body: String) -> PushText {
        PushText(title: text.title, subtitle: text.subtitle, body: body)
    }

    private static func with(_ text: PushText, subtitle: String) -> PushText {
        PushText(title: text.title, subtitle: subtitle, body: text.body)
    }

    /// `text` as it is, or its first `limit - 1` characters and an ellipsis.
    private static func cut(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + ellipsis
    }

    /// The longest of `string`'s cuts (a prefix of whole characters, then an ellipsis) that `fits`, assuming
    /// that a longer cut never fits when a shorter one does not; nil if even the ellipsis alone does not fit or
    /// there is nothing to cut.
    private static func longestCut(of string: String, fits: (String) throws -> Bool) rethrows -> String? {
        let characters = Array(string)
        guard !characters.isEmpty else { return nil }
        func cut(_ count: Int) -> String { String(characters[..<count]) + ellipsis }
        guard try fits(cut(0)) else { return nil }
        var low = 0
        var high = characters.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if try fits(cut(middle)) { low = middle } else { high = middle - 1 }
        }
        return cut(low)
    }

    private static func serialize(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func size(_ object: [String: Any]) throws -> Int {
        try serialize(object).count
    }
}
