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

@Test func aResponseAnswersOrOpensWhatTheNotificationIsAbout() {
    let tap = "com.apple.UNNotificationDefaultActionIdentifier"
    func alert(_ category: PushCategory, _ requestId: String? = "r1", session: String = "s1") -> ParsedPush.Alert {
        ParsedPush.Alert(category: category, requestId: requestId, sessionId: session, sealed: "x")
    }
    func response(_ action: String, _ alert: ParsedPush.Alert?, text: String? = nil) -> NotificationResponse {
        NotificationAnswer.response(action: action, text: text, alert: alert)
    }

    // A permission request's buttons answer it, in the background.
    #expect(response(NotificationAction.allow.rawValue, alert(.permission))
        == .answer(requestId: "r1", payload: AnswerPayload(decision: "allow")))
    #expect(response(NotificationAction.deny.rawValue, alert(.permissionNoReason))
        == .answer(requestId: "r1", payload: AnswerPayload(decision: "deny")))
    #expect(response(NotificationAction.denyWithReason.rawValue, alert(.permission), text: " 换个目录 ")
        == .answer(requestId: "r1", payload: AnswerPayload(decision: "deny", message: "换个目录")))

    // The notification itself and 「打开」 open the request's card (it is looked up by id: gone, it says so).
    for category in [PushCategory.permission, .permissionNoReason, .question, .plan] {
        #expect(response(tap, alert(category)) == .openRequest("r1"))
    }
    #expect(response(NotificationAction.open.rawValue, alert(.question)) == .openRequest("r1"))
    // A question or a plan is never answered from its notification, whatever the button says.
    #expect(response(NotificationAction.allow.rawValue, alert(.plan)) == .openRequest("r1"))

    // A session's notification opens its details.
    for category in [PushCategory.waitingElsewhere, .done, .error] {
        #expect(response(tap, alert(category, nil, session: "s9")) == .openSession("s9"))
    }
    // The test notification, and a notification that is not Critter's: just the app.
    #expect(response(tap, alert(.test, nil, session: "test")) == .openApp)
    #expect(response(tap, nil) == .openApp)
    // A request without its id (broken): the app, no answer.
    #expect(response(NotificationAction.allow.rawValue, alert(.permission, nil)) == .openApp)
    // Swiped away: nothing.
    #expect(response("com.apple.UNNotificationDismissActionIdentifier", alert(.permission)) == .nothing)
}

@Test func aResultNotificationSaysWhatItWasAbout() {
    // The request's own title (what the extension opened) stays under the result, so a "没送到" can be tried again
    // knowing what for; the plain "Critter" says nothing and is left out.
    let about = "clawd 想 运行 swift test"
    #expect(BackgroundAnswerResult.answered(decision: "allow").notificationText(about: about)
        == NotificationResultText(title: "已允许", body: about, keepButtons: false))
    #expect(BackgroundAnswerResult.unreachable.notificationText(about: about)
        == NotificationResultText(title: "没送到：连不上 Mac（要和电脑在同一个 Wi‑Fi）", body: about, keepButtons: true))
    #expect(BackgroundAnswerResult.resolved.notificationText(about: "Critter")
        == NotificationResultText(title: "已在电脑上处理", body: "", keepButtons: false))
    #expect(BackgroundAnswerResult.expired.notificationText(about: nil) == BackgroundAnswerResult.expired.notificationText)
}
