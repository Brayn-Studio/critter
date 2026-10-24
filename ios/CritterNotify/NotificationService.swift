import UserNotifications

/// The notification service extension (spec §8.7): it gets every push with `mutable-content` before it is shown.
/// For now it hands the push on as it came ("Critter / 有会话需要你"); opening the sealed text is plan 4's Task 5.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    /// The best version so far: what goes out if the system ends the extension early.
    private var best: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        #if DEBUG
        if request.content.userInfo["critterSharedCheck"] != nil { SharedCheck.answer(content) }
        #endif
        best = content
        finish(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let best { finish(best) }
    }

    /// Hands `content` to the system, once.
    private func finish(_ content: UNNotificationContent) {
        contentHandler?(content)
        contentHandler = nil
    }
}
