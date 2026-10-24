import Foundation

/// What a notification shows once the notification service extension has looked at its push (spec §8.7, §11).
public struct NotificationLook: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var body: String
    /// What the push is about (its `k`).
    public var category: PushCategory
    /// `categoryIdentifier`: which buttons it has (`PushOpening.categoryId`). The push's own category when the text
    /// opened; when it did not, a request its buttons would answer from the notification gets
    /// `PushOpening.sealedCategory` (only 「打开」) instead: the user would allow or deny what they cannot see. The other
    /// categories keep theirs (their buttons, if any, only open the app).
    public var categoryId: String { PushOpening.categoryId(category, opened: opened) }
    /// `threadIdentifier`: the session, so one session's notifications group together.
    public var threadId: String
    /// `interruptionLevel = .timeSensitive`: a session waits for the user.
    public var timeSensitive: Bool
    /// Whether the sealed text opened. When it did not, the words are the push's plain "Critter / 有会话需要你".
    public var opened: Bool

    public init(
        title: String, subtitle: String, body: String, category: PushCategory, threadId: String, timeSensitive: Bool,
        opened: Bool
    ) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.category = category
        self.threadId = threadId
        self.timeSensitive = timeSensitive
        self.opened = opened
    }
}

extension PushCategory {
    /// A session waits for the user: a request, or something only the computer can answer. The Mac sends these
    /// `time-sensitive` (`PushContent`), and the phone shows them so (spec §8.7); done, error and the test are not.
    public var waitsForTheUser: Bool {
        switch self {
        case .permission, .permissionNoReason, .question, .plan, .waitingElsewhere: true
        case .done, .error, .test: false
        }
    }

    /// Its notification's buttons answer the request from the notification, without the app (「允许」「拒绝」
    /// 「拒绝并写理由…」): a permission request. A question's or a plan's 「打开」 only opens its card.
    public var answersFromItsNotification: Bool {
        switch self {
        case .permission, .permissionNoReason: true
        case .question, .plan, .waitingElsewhere, .done, .error, .test: false
        }
    }
}

/// The notification service extension's work, without the extension (spec §8.7): read the push the Mac sent
/// (`PushPayload.parse`), open its sealed text with the push key (`PushCrypto.open`, bound to the push's `k|r|s`), and
/// say what the notification shows. Pure, so it is tested on the Mac; the extension only reads the key from the shared
/// keychain and copies the result into the notification's content.
public enum PushOpening {
    /// The notification category of a permission request whose text did not open: only 「打开」, which brings the app up
    /// with the request's card (spec §11). The app registers it with the others (`NotificationAnswer.categories`); it is
    /// not a `PushCategory`. The Mac sends it as such a push's `aps.category` (`PushPayload.alert`), the real one only
    /// in `k`, so that a notification the extension never got to (or that the system took back from it early) has no
    /// answering buttons either.
    public static let sealedCategory = "sealed"

    /// The `categoryIdentifier` of a notification about `category`: its own, unless its text did not open and its
    /// buttons would answer the request (`answersFromItsNotification`): then `sealedCategory`. With `opened: false`
    /// it is also the push's `aps.category`: what iOS shows when the extension does not run.
    public static func categoryId(_ category: PushCategory, opened: Bool) -> String {
        opened || !category.answersFromItsNotification ? category.rawValue : sealedCategory
    }

    /// What the notification for `userInfo` shows, opened with `key` (nil: there is none, or the keychain cannot be
    /// read, as before the first unlock).
    ///
    /// - A text that does not open (another key, no key, a broken or moved sealed text, not a notification's text
    ///   inside) leaves the plain `PushPayload.title` / `PushPayload.body`, with the thread and level all the same; a
    ///   permission request then offers only 「打开」 (`sealedCategory`), never 「允许」「拒绝」 for a command the user
    ///   cannot see (spec §11).
    /// - nil for a push that is not one of Critter's notifications as this build knows them (a category it does not
    ///   know, no session or sealed text, a withdrawal): the extension hands it on as it came.
    public static func look(_ userInfo: [AnyHashable: Any], key: String?) -> NotificationLook? {
        guard case .alert(let alert)? = PushPayload.parse(userInfo) else { return nil }
        let text = key.flatMap { try? PushCrypto.open(alert, key: $0) }
        return NotificationLook(
            title: text?.title ?? PushPayload.title, subtitle: text?.subtitle ?? "", body: text?.body ?? PushPayload.body,
            category: alert.category, threadId: alert.sessionId, timeSensitive: alert.category.waitsForTheUser,
            opened: text != nil
        )
    }
}
