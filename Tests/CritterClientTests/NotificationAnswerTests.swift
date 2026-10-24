import CritterClient
import CritterKit
import Testing

// What a notification's buttons send (spec §8.7): only permission requests are answered from the notification.

@Test func allowDenyAndReasonMapToAnswers() {
    func payload(_ action: String, _ text: String? = nil) -> AnswerPayload? {
        NotificationAnswer.payload(action: action, text: text, kind: .permission, acceptsDenyMessage: true)
    }
    #expect(payload(NotificationAction.allow.rawValue) == AnswerPayload(decision: "allow"))
    #expect(payload(NotificationAction.deny.rawValue) == AnswerPayload(decision: "deny"))
    // The reason is what was typed, trimmed; nothing typed is a plain "拒绝".
    #expect(payload(NotificationAction.denyWithReason.rawValue, "  换个目录再跑 \n") == AnswerPayload(decision: "deny", message: "换个目录再跑"))
    #expect(payload(NotificationAction.denyWithReason.rawValue, "  ") == AnswerPayload(decision: "deny"))
    #expect(payload(NotificationAction.denyWithReason.rawValue) == AnswerPayload(decision: "deny"))
    // Allow carries no text, whatever came with it.
    #expect(payload(NotificationAction.allow.rawValue, "x") == AnswerPayload(decision: "allow"))
    // Tapping the notification itself, or anything else: no answer, the app opens the card.
    #expect(payload("com.apple.UNNotificationDefaultActionIdentifier") == nil)
    #expect(payload(NotificationAction.open.rawValue) == nil)

    // The buttons a permission request shows, in order; every one asks to unlock first.
    let buttons = NotificationAnswer.buttons(for: .permission)
    #expect(buttons.map(\.title) == ["允许", "拒绝", "拒绝并写理由…"])
    #expect(buttons.map(\.action) == [.allow, .deny, .denyWithReason])
    #expect(buttons.map(\.takesText) == [false, false, true])
    #expect(buttons.allSatisfy { $0.needsUnlock && !$0.opensApp })
}

@Test func codexHasNoReasonButton() {
    // A Codex permission request (`permissionNoReason`) cannot be denied with a reason (spec §8.7).
    let buttons = NotificationAnswer.buttons(for: .permissionNoReason)
    #expect(buttons.map(\.title) == ["允许", "拒绝"])
    #expect(NotificationAnswer.acceptsDenyMessage(.permissionNoReason) == false)
    #expect(NotificationAnswer.acceptsDenyMessage(.permission) == true)
    // A reason that comes anyway is not sent: the answer is a plain "拒绝".
    #expect(NotificationAnswer.payload(action: NotificationAction.denyWithReason.rawValue, text: "不行", kind: .permission, acceptsDenyMessage: false)
        == AnswerPayload(decision: "deny"))
    #expect(NotificationAnswer.payload(action: NotificationAction.denyWithReason.rawValue, text: "不行", category: .permissionNoReason)
        == AnswerPayload(decision: "deny"))
    #expect(NotificationAnswer.payload(action: NotificationAction.denyWithReason.rawValue, text: "不行", category: .permission)
        == AnswerPayload(decision: "deny", message: "不行"))
}

@Test func questionsAndPlansHaveNoNotificationAnswer() {
    for kind in [PendingKind.question, .plan] {
        for action in NotificationAction.allCases {
            #expect(NotificationAnswer.payload(action: action.rawValue, text: "x", kind: kind, acceptsDenyMessage: true) == nil)
        }
    }
    for category in [PushCategory.question, .plan] {
        #expect(NotificationAnswer.payload(action: NotificationAction.allow.rawValue, text: nil, category: category) == nil)
        // Only "打开": it brings the app up with the card.
        let buttons = NotificationAnswer.buttons(for: category)
        #expect(buttons.map(\.title) == ["打开"])
        #expect(buttons.map(\.action) == [.open])
        #expect(buttons.allSatisfy { $0.opensApp && !$0.takesText })
    }
    // Notifications about a session have no buttons: tapping one opens the app.
    for category in [PushCategory.waitingElsewhere, .done, .error, .test] {
        #expect(NotificationAnswer.buttons(for: category).isEmpty)
        #expect(NotificationAnswer.payload(action: NotificationAction.allow.rawValue, text: nil, category: category) == nil)
    }
}
