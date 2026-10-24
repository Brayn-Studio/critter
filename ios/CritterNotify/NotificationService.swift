import CritterKit
import os
import UserNotifications

/// The notification service extension (spec §8.7): it gets every push with `mutable-content` before it is shown, and
/// opens its sealed text with the push key from the shared keychain (`PushOpening`, which holds the rules and their
/// tests): the real title, subtitle and body replace "Critter / 有会话需要你"; the category (the buttons), the thread
/// (the session) and, for a session that waits for the user, the time-sensitive level are set. A text that does not
/// open -- no key yet, the keychain locked before the first unlock, another key, a moved or broken text -- keeps the
/// plain words, and a permission request then offers only 「打开」 (`PushOpening.sealedCategory`), never 「允许」「拒绝」
/// for a command the user cannot see (spec §11). Until the text has opened the content already carries that open-only
/// category, so a notification the system hands on early (`serviceExtensionTimeWillExpire`) has no answering buttons
/// either. The key and the text are never logged.
final class NotificationService: UNNotificationServiceExtension {
    private static let log = Logger(subsystem: "com.braynlabs.critter", category: "notify")

    private var contentHandler: ((UNNotificationContent) -> Void)?
    /// The best version so far: what goes out if the system ends the extension early.
    private var best: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        best = content
        #if DEBUG
        if request.content.userInfo["critterSharedCheck"] != nil {
            SharedCheck.answer(content)
            finish(content)
            return
        }
        #endif
        let userInfo = request.content.userInfo
        // What goes out if the system ends the extension before the text has opened: no buttons that answer.
        if let sealed = PushOpening.look(userInfo, key: nil) { Self.apply(sealed, to: content) }
        if let look = PushOpening.look(userInfo, key: Self.pushKey()) {
            Self.apply(look, to: content)
            Self.log.notice(
                "push \(request.identifier, privacy: .public): \(look.category.rawValue, privacy: .public), opened \(look.opened), buttons \(look.categoryId, privacy: .public)"
            )
        } else {
            Self.log.notice("push \(request.identifier, privacy: .public): not a notification of this build's, as it came")
        }
        finish(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let best { finish(best) }
    }

    /// The words when they opened; the category (the push's own, or the open-only one: `NotificationLook.categoryId`),
    /// thread and level either way.
    private static func apply(_ look: NotificationLook, to content: UNMutableNotificationContent) {
        if look.opened {
            content.title = look.title
            content.subtitle = look.subtitle
            content.body = look.body
        }
        content.categoryIdentifier = look.categoryId
        content.threadIdentifier = look.threadId
        content.interruptionLevel = look.timeSensitive ? .timeSensitive : .active
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

    /// Hands `content` to the system, once.
    private func finish(_ content: UNNotificationContent) {
        contentHandler?(content)
        contentHandler = nil
    }
}
