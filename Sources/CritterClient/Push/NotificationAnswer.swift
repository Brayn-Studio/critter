import CritterKit

/// The ids of a notification's buttons (`UNNotificationAction.identifier`).
public enum NotificationAction: String, CaseIterable, Sendable {
    case allow
    case deny
    /// "拒绝并写理由…": comes with the text typed in.
    case denyWithReason
    /// "打开": brings the app up with the request's card.
    case open
}

/// One button of a notification category, as the app registers it (spec §8.7).
public struct NotificationButton: Equatable, Sendable {
    public var action: NotificationAction
    public var title: String
    /// A text field comes with it (`UNTextInputNotificationAction`).
    public var takesText: Bool
    /// The phone must be unlocked first (`.authenticationRequired`): every button that answers.
    public var needsUnlock: Bool
    /// It brings the app to the foreground (`.foreground`) instead of answering from the notification.
    public var opensApp: Bool
}

/// What a notification's buttons are, and what each one sends (spec §8.7). Only a permission request is answered
/// from its notification; a question or a plan only opens its card, and so does a permission request whose text did
/// not open (`PushOpening.sealedCategory`).
public enum NotificationAnswer {
    private static let allow = NotificationButton(action: .allow, title: "允许", takesText: false, needsUnlock: true, opensApp: false)
    private static let deny = NotificationButton(action: .deny, title: "拒绝", takesText: false, needsUnlock: true, opensApp: false)
    private static let reason = NotificationButton(
        action: .denyWithReason, title: "拒绝并写理由…", takesText: true, needsUnlock: true, opensApp: false
    )
    private static let open = NotificationButton(action: .open, title: "打开", takesText: false, needsUnlock: true, opensApp: true)

    /// The buttons of a notification of `category`, in order.
    public static func buttons(for category: PushCategory) -> [NotificationButton] {
        switch category {
        case .permission: return [allow, deny, reason]
        case .permissionNoReason: return [allow, deny]
        case .question, .plan: return [open]
        case .waitingElsewhere, .done, .error, .test: return []
        }
    }

    /// The buttons of a permission request whose text did not open (`PushOpening.sealedCategory`): 「打开」 only, which
    /// brings up the request's card -- never an answer to a command the user cannot see.
    public static let sealedButtons = [open]

    /// Every notification category the app registers, by its id, with its buttons: each `PushCategory`, and the
    /// open-only one a permission request's push comes with (`PushPayload.alert`) and keeps while its text has not
    /// opened.
    public static var categories: [(id: String, buttons: [NotificationButton])] {
        PushCategory.allCases.map { (id: $0.rawValue, buttons: buttons(for: $0)) }
            + [(id: PushOpening.sealedCategory, buttons: sealedButtons)]
    }

    /// Whether a request of this category may be denied with a reason: not a Codex one (`permissionNoReason`).
    public static func acceptsDenyMessage(_ category: PushCategory) -> Bool {
        category != .permissionNoReason
    }

    /// The answer the button `action` gives a request of `kind`, `text` being what was typed with it; nil when the
    /// button does not answer (the notification itself, "打开", or a question or plan: their card does). A reason
    /// is sent only where the request takes one (`acceptsDenyMessage`); otherwise it is a plain "拒绝".
    public static func payload(action: String, text: String?, kind: PendingKind, acceptsDenyMessage: Bool) -> AnswerPayload? {
        guard kind == .permission, let action = NotificationAction(rawValue: action) else { return nil }
        switch action {
        case .allow:
            return AnswerPayload(decision: "allow")
        case .deny:
            return AnswerPayload(decision: "deny")
        case .denyWithReason:
            let reason = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return AnswerPayload(decision: "deny", message: acceptsDenyMessage && !reason.isEmpty ? reason : nil)
        case .open:
            return nil
        }
    }

    /// `payload(action:text:kind:acceptsDenyMessage:)` for a notification of `category`.
    public static func payload(action: String, text: String?, category: PushCategory) -> AnswerPayload? {
        guard category == .permission || category == .permissionNoReason else { return nil }
        return payload(action: action, text: text, kind: .permission, acceptsDenyMessage: acceptsDenyMessage(category))
    }
}

/// What the app does with a response to one of its notifications (spec §8.4, §8.7).
public enum NotificationResponse: Equatable, Sendable {
    /// Send this answer to the request, in the background (`BackgroundAnswer`), and put the result in the
    /// notification's place.
    case answer(requestId: String, payload: AnswerPayload)
    /// Bring the app up with the request's answer card. The card looks the request up by id: one that is gone says
    /// that the computer has it.
    case openRequest(String)
    /// Bring the app up with the session's details: done, failed, or waiting for the computer.
    case openSession(String)
    /// Just the app: the test notification, or one that is not Critter's.
    case openApp
    /// The notification was swiped away.
    case nothing
}

extension NotificationAnswer {
    /// The system's ids for a tap on the notification itself and for swiping it away
    /// (`UNNotificationDefaultActionIdentifier`, `UNNotificationDismissActionIdentifier`).
    public static let tapAction = "com.apple.UNNotificationDefaultActionIdentifier"
    public static let dismissAction = "com.apple.UNNotificationDismissActionIdentifier"

    /// What a response to a notification does: `action` is the button's id (or the system's, `tapAction`), `text`
    /// what was typed with it, `alert` the push the notification came from (nil: not Critter's). Only a permission
    /// request's buttons answer; everything else opens what the notification is about.
    public static func response(action: String, text: String?, alert: ParsedPush.Alert?) -> NotificationResponse {
        if action == dismissAction { return .nothing }
        guard let alert else { return .openApp }
        switch alert.category {
        case .permission, .permissionNoReason, .question, .plan:
            guard let requestId = alert.requestId else { return .openApp }
            if let payload = payload(action: action, text: text, category: alert.category) {
                return .answer(requestId: requestId, payload: payload)
            }
            return .openRequest(requestId)
        case .waitingElsewhere, .done, .error:
            return .openSession(alert.sessionId)
        case .test:
            return .openApp
        }
    }
}
