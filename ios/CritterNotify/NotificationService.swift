import CritterKit
import Foundation
import os
import UserNotifications

/// The notification service extension (spec §8.7): it gets every push with `mutable-content` before it is shown, and
/// opens its sealed text with the push key from the shared keychain (`PushOpening`, which holds the rules and their
/// tests): the real title, subtitle and body replace "Critter / 有会话需要你"; the category (the buttons), the thread
/// (the session) and, for a session that waits for the user, the time-sensitive level are set.
///
/// A permission request's push comes with the open-only category (`PushOpening.sealedCategory`: only 「打开」), its real
/// one only in `k` (`PushPayload.alert`): a notification the extension never gets to has no 「允许」「拒绝」. The extension
/// switches to `k` only once the text has opened. A text that does not open -- no key yet, the keychain locked before
/// the first unlock, another key, a moved or broken text -- keeps the plain words and the open-only category, never
/// 「允许」「拒绝」 for a command the user cannot see (spec §11). If the system ends the extension early
/// (`serviceExtensionTimeWillExpire`), what goes out is that open-only version, unless the opened one was already
/// complete. The key and the text are never logged.
final class NotificationService: UNNotificationServiceExtension {
    private static let log = Logger(subsystem: "com.braynlabs.critter", category: "notify")

    /// `didReceive` and `serviceExtensionTimeWillExpire` may come on different threads: `contentHandler` and `best`
    /// are only touched under it.
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    /// What goes out if the system ends the extension early: the push as it came, then its open-only version. Never the
    /// opened one: that goes straight out (`finish`), and once it has, there is nothing left to end early.
    private var best: UNNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        lock.withLock {
            self.contentHandler = contentHandler
            best = request.content
        }
        #if DEBUG
        if request.content.userInfo["critterSharedCheck"] != nil {
            let content = Self.copy(request.content)
            SharedCheck.answer(content)
            finish(content)
            return
        }
        #endif
        let userInfo = request.content.userInfo
        // The open-only version, made before the key is read: no button that answers, and no words.
        if let sealed = PushOpening.look(userInfo, key: nil) {
            let early = Self.content(request.content, showing: sealed)
            lock.withLock { best = early }
        }
        guard let look = PushOpening.look(userInfo, key: Self.pushKey()) else {
            Self.log.notice("push \(request.identifier, privacy: .public): not a notification of this build's, as it came")
            finish(request.content)
            return
        }
        let shown = Self.content(request.content, showing: look)
        Self.log.notice(
            "push \(request.identifier, privacy: .public): \(look.category.rawValue, privacy: .public), opened \(look.opened), buttons \(look.categoryId, privacy: .public)"
        )
        finish(shown)
    }

    override func serviceExtensionTimeWillExpire() {
        finish(nil)
    }

    /// `original` as `look` says: the words when they opened; the category (`k` once the text opened, otherwise what
    /// `NotificationLook.categoryId` says: the open-only one for a permission request), thread and level either way.
    private static func content(_ original: UNNotificationContent, showing look: NotificationLook) -> UNNotificationContent {
        let content = copy(original)
        if look.opened {
            content.title = look.title
            content.subtitle = look.subtitle
            content.body = look.body
        }
        content.categoryIdentifier = look.categoryId
        content.threadIdentifier = look.threadId
        content.interruptionLevel = look.timeSensitive ? .timeSensitive : .active
        return content
    }

    private static func copy(_ content: UNNotificationContent) -> UNMutableNotificationContent {
        (content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
    }

    /// The push key the app made (`SharedKeychain.pushKeyAccount`), or nil: none yet, or the keychain cannot be read
    /// now (only its status is logged).
    private static func pushKey() -> String? {
        switch SharedKeychain.push.read(SharedKeychain.pushKeyAccount) {
        case .found(let data): return String(data: data, encoding: .utf8)
        case .missing: return nil
        case .failed(let status):
            log.error("reading the push key failed: \(status)")
            return nil
        }
    }

    /// Hands `content` (nil: the best version so far) to the system, once.
    private func finish(_ content: UNNotificationContent?) {
        let (handler, chosen) = lock.withLock { () -> (((UNNotificationContent) -> Void)?, UNNotificationContent?) in
            defer { contentHandler = nil }
            return (contentHandler, content ?? best)
        }
        if let handler, let chosen { handler(chosen) }
    }
}
