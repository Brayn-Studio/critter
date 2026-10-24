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
/// from its notification; a question or a plan only opens its card.
public enum NotificationAnswer {
    /// The buttons of a notification of `category`, in order.
    public static func buttons(for category: PushCategory) -> [NotificationButton] {
        let allow = NotificationButton(action: .allow, title: "允许", takesText: false, needsUnlock: true, opensApp: false)
        let deny = NotificationButton(action: .deny, title: "拒绝", takesText: false, needsUnlock: true, opensApp: false)
        let reason = NotificationButton(action: .denyWithReason, title: "拒绝并写理由…", takesText: true, needsUnlock: true, opensApp: false)
        let open = NotificationButton(action: .open, title: "打开", takesText: false, needsUnlock: true, opensApp: true)
        switch category {
        case .permission: return [allow, deny, reason]
        case .permissionNoReason: return [allow, deny]
        case .question, .plan: return [open]
        case .waitingElsewhere, .done, .error, .test: return []
        }
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
