import CritterClient
import CritterKit
import Testing

// Which notifications the app shows as banners, and which it takes down when it comes to the foreground (spec §8.7).

@Test func aRequestAlreadyOnScreenDoesNotBanner() {
    let snapshot = fixtureBody([fixtureSession("s1", state: .waiting)], pending: [fixturePending("r1", "s1")])
    // In the foreground the request is on screen already: a light tap instead of a banner.
    #expect(!NotificationRules.showBanner(requestId: "r1", snapshot: snapshot, isForeground: true))
    // In the background, or a request the screen does not show yet: a banner.
    #expect(NotificationRules.showBanner(requestId: "r1", snapshot: snapshot, isForeground: false))
    #expect(NotificationRules.showBanner(requestId: "r2", snapshot: snapshot, isForeground: true))
    #expect(NotificationRules.showBanner(requestId: "r1", snapshot: nil, isForeground: true))
    // Not about a request (done, error, 请在电脑上处理, the test): a banner.
    #expect(NotificationRules.showBanner(requestId: nil, snapshot: snapshot, isForeground: true))
}

@Test func staleNotificationsAreWithdrawnOnForeground() {
    let snapshot = fixtureBody(
        [
            fixtureSession("s1", state: .done), fixtureSession("s2", state: .running), fixtureSession("s4", state: .waiting),
            fixtureSession("s5", state: .running), fixtureSession("s6", state: .error), fixtureSession("s7", state: .waiting),
        ],
        pending: [fixturePending("r1", "s4")]
    )
    func notice(_ id: String, _ category: PushCategory?) -> DeliveredNotification {
        DeliveredNotification(id: id, category: category?.rawValue)
    }
    let delivered = [
        notice("r1", .permission),  // still waiting: stays
        notice("r2", .question),  // answered or gone: withdrawn
        notice("r3", nil),  // a result shown in its place ("已允许"): the request is gone, so it goes too
        notice("done:s1", .done),  // still done: stays
        notice("done:s2", .done),  // running again: withdrawn
        notice("error:s3", .error),  // the session ended: withdrawn
        notice("error:s6", .error),  // still failing: stays
        notice("waitingElsewhere:s7", .waitingElsewhere),  // still waiting, nothing to answer here: stays
        notice("waitingElsewhere:s4", .waitingElsewhere),  // waiting, but for a request the phone answers: withdrawn
        notice("waitingElsewhere:s5", .waitingElsewhere),  // moved on: withdrawn
        notice("2F1B7C1E-5B2A-4E8E-9C2D-3F4A5B6C7D8E", .test),  // the test notification: not the snapshot's business
    ]
    #expect(NotificationRules.staleNotificationIds(delivered: delivered, snapshot: snapshot)
        == ["r2", "r3", "done:s2", "error:s3", "waitingElsewhere:s4", "waitingElsewhere:s5"])
    #expect(NotificationRules.staleNotificationIds(delivered: [], snapshot: snapshot).isEmpty)
}

@Test func aWaitingNoticeGoesOnceItsSessionHasARequest() {
    // "请在电脑上处理" is for a session waiting with nothing the phone can answer. The Mac takes it down once that
    // session has a request the phone answers (`PushTracker`); the phone does the same when it comes to the foreground,
    // since the withdrawal may never have arrived. The request's own notification stays.
    let notices = [
        DeliveredNotification(id: "waitingElsewhere:s1", category: PushCategory.waitingElsewhere.rawValue),
        DeliveredNotification(id: "r1", category: PushCategory.permission.rawValue),
    ]
    let nothingToAnswer = fixtureBody([fixtureSession("s1", state: .waiting)])
    #expect(NotificationRules.staleNotificationIds(delivered: notices, snapshot: nothingToAnswer) == ["r1"])
    let withRequest = fixtureBody([fixtureSession("s1", state: .waiting)], pending: [fixturePending("r1", "s1")])
    #expect(NotificationRules.staleNotificationIds(delivered: notices, snapshot: withRequest) == ["waitingElsewhere:s1"])
    // A request of another session does not count.
    let elsewhere = fixtureBody(
        [fixtureSession("s1", state: .waiting), fixtureSession("s2", state: .waiting)], pending: [fixturePending("r1", "s2")]
    )
    #expect(NotificationRules.staleNotificationIds(delivered: notices, snapshot: elsewhere).isEmpty)
}
