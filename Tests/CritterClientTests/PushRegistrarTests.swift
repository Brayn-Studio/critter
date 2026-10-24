import CritterClient
import CritterKit
import Testing

// When the phone registers for push with the Mac, what it sends, and what its settings say (spec §6.2, §8.3, §8.8).

private let key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

private func registrar(
    deviceToken: String? = "aa11", notificationsAllowed: Bool = true, done: Bool = false, error: Bool = false,
    activity: ActivityRegistration = ActivityRegistration(enabled: true, startToken: "5a5a")
) -> PushRegistrar {
    PushRegistrar(
        deviceToken: deviceToken, environment: .sandbox, bundleId: "com.braynlabs.critter", key: key,
        notificationsAllowed: notificationsAllowed, notifyDone: done, notifyError: error, liveActivity: activity
    )
}

@Test func registrationChangesAreSentOnce() {
    let phone = registrar(done: true)
    let sent = phone.registration()
    #expect(sent == PushRegistration(
        token: "aa11", environment: .sandbox, bundleId: "com.braynlabs.critter", key: key, notifyDone: true, notifyError: false,
        activity: ActivityRegistration(enabled: true, startToken: "5a5a")
    ))
    // Never confirmed: sent.
    var acked = PushAck()
    #expect(phone.shouldSend(acked: acked, macVersion: "1.5.0"))
    // The Mac keeps it: not again, connection after connection.
    acked = phone.record(reply: .stored("已登记"), sent: sent, macVersion: "1.5.0", acked: acked)
    #expect(acked.stored == sent)
    #expect(!phone.shouldSend(acked: acked, macVersion: "1.5.0"))

    // Each thing the Mac relies on, changed, is sent once more: the token, the key, a switch, a Live Activity token.
    var changed = [registrar(deviceToken: "bb22", done: true), registrar(done: false), registrar(done: true, error: true)]
    var withKey = registrar(done: true)
    withKey.key = "BAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    var withActivity = registrar(done: true)
    withActivity.liveActivity = ActivityRegistration(enabled: true, startToken: "5a5a", activityId: "A1", activityToken: "9f9f")
    changed += [withKey, withActivity]
    for next in changed {
        #expect(next.shouldSend(acked: acked, macVersion: "1.5.0"))
        let again = next.record(reply: .stored("已登记"), sent: next.registration(), macVersion: "1.5.0", acked: acked)
        #expect(!next.shouldSend(acked: again, macVersion: "1.5.0"))
    }

    // Tokens are written as the Mac takes them: lowercase hex, an empty one is none.
    let upper = registrar(deviceToken: "AA11", activity: ActivityRegistration(enabled: true, startToken: "", activityId: "", activityToken: "9F9F"))
    #expect(upper.registration().token == "aa11")
    #expect(upper.registration().activity == ActivityRegistration(enabled: true, startToken: nil, activityId: nil, activityToken: "9f9f"))

    // A refusal is not a confirmation: tried again on the next connection.
    let refused = phone.record(reply: .rejected("保存失败"), sent: sent, macVersion: "1.5.0", acked: PushAck())
    #expect(phone.shouldSend(acked: refused, macVersion: "1.5.0"))
    // Nor is a registration cut off on its way.
    #expect(phone.record(reply: .offline, sent: sent, macVersion: "1.5.0", acked: PushAck()) == PushAck())

    // No device token yet (it comes a moment after launch): nothing to register, and no unregistration either.
    #expect(!registrar(deviceToken: nil).shouldSend(acked: acked, macVersion: "1.5.0"))
    #expect(!registrar(deviceToken: "").shouldSend(acked: PushAck(), macVersion: "1.5.0"))
}

@Test func theMacIsAskedAgainWhenItRunsAnotherVersionOrHadNoPushSetup() {
    let phone = registrar()
    let sent = phone.registration()
    // Stored by a Mac without a push setup: asked again on the next connection, it may have one by then.
    let unready = phone.record(reply: .stored("已登记；这台 Mac 还没配置推送"), sent: sent, macVersion: "1.5.0", acked: PushAck())
    #expect(phone.shouldSend(acked: unready, macVersion: "1.5.0"))
    // Stored by a Mac that can push, or one that says nothing about it: settled.
    let ready = phone.record(reply: .stored("已登记"), sent: sent, macVersion: "1.5.0", acked: PushAck())
    #expect(!phone.shouldSend(acked: ready, macVersion: "1.5.0"))
    let quiet = phone.record(reply: .stored(nil), sent: sent, macVersion: "1.5.0", acked: PushAck())
    #expect(!phone.shouldSend(acked: quiet, macVersion: "1.5.0"))
    // The Mac now runs another version (it may not have kept what the old one stored): once more.
    #expect(phone.shouldSend(acked: ready, macVersion: "1.6.0"))
}

@Test func everythingOffSendsAnEmptyToken() {
    // Notifications switched off in the system's settings and the Live Activity off: no pushes at all, so the
    // registration is taken back -- the only shape that does that is an empty token (protocol doc).
    let off = registrar(notificationsAllowed: false, activity: ActivityRegistration(enabled: false, startToken: "5a5a"))
    let sent = off.registration()
    #expect(sent.token.isEmpty)
    #expect(sent == off.unregistration())
    let wasOn = registrar().record(reply: .stored("已登记"), sent: registrar().registration(), macVersion: "1.5.0", acked: PushAck())
    #expect(off.shouldSend(acked: wasOn, macVersion: "1.5.0"))
    let after = off.record(reply: .stored(nil), sent: sent, macVersion: "1.5.0", acked: wasOn)
    #expect(!off.shouldSend(acked: after, macVersion: "1.5.0"))
    // Also without a device token: an unregistration needs none.
    #expect(registrar(deviceToken: nil, notificationsAllowed: false, activity: ActivityRegistration(enabled: false))
        .shouldSend(acked: wasOn, macVersion: "1.5.0"))

    // Either one on is still a registration: a waiting session is always pushed, and the activity needs the token.
    #expect(!registrar(notificationsAllowed: false).registration().token.isEmpty)
    #expect(!registrar(activity: ActivityRegistration(enabled: false)).registration().token.isEmpty)
    // The reminders off is not "everything off": waiting sessions are still pushed.
    #expect(!registrar(done: false, error: false, activity: ActivityRegistration(enabled: false)).registration().token.isEmpty)
}

@Test func anOldMacIsTriedOncePerVersion() {
    let phone = registrar()
    let sent = phone.registration()
    // No reply within 10 s: a Mac that does not know the frame.
    let silent = phone.record(reply: .noReply, sent: sent, macVersion: "1.3.0", acked: PushAck())
    #expect(phone.status(acked: silent, macVersion: "1.3.0") == "这台 Mac 上的 Critter 版本太旧，收不到推送")
    // Not tried again on that version, whatever changes on the phone.
    #expect(!phone.shouldSend(acked: silent, macVersion: "1.3.0"))
    #expect(!registrar(done: true).shouldSend(acked: silent, macVersion: "1.3.0"))
    // The Mac is updated: tried again, and the old version is forgotten once it answers.
    #expect(phone.shouldSend(acked: silent, macVersion: "1.5.0"))
    #expect(phone.status(acked: silent, macVersion: "1.5.0") == "还没登记（要连上 Mac）")
    let stored = phone.record(reply: .stored("已登记"), sent: sent, macVersion: "1.5.0", acked: silent)
    #expect(stored.silentMacVersion == nil)
    #expect(phone.status(acked: stored, macVersion: "1.5.0") == "已登记")
}

@Test func theMacsStatusLineIsShown() {
    let phone = registrar()
    let sent = phone.registration()
    #expect(phone.status(acked: PushAck(), macVersion: nil) == "还没登记（要连上 Mac）")
    // What the Mac said when it stored it.
    let unready = phone.record(reply: .stored("已登记；这台 Mac 还没配置推送"), sent: sent, macVersion: "1.5.0", acked: PushAck())
    #expect(phone.status(acked: unready, macVersion: "1.5.0") == "已登记；这台 Mac 还没配置推送")
    // A Mac that says nothing: "已登记".
    let quiet = phone.record(reply: .stored(nil), sent: sent, macVersion: "1.5.0", acked: PushAck())
    #expect(phone.status(acked: quiet, macVersion: "1.5.0") == "已登记")
    // Its refusal, in its words, until something else is registered.
    let refused = phone.record(reply: .rejected("推送登记无效"), sent: sent, macVersion: "1.5.0", acked: quiet)
    #expect(phone.status(acked: refused, macVersion: "1.5.0") == "已登记")
    let refusedFirst = phone.record(reply: .rejected("推送登记无效"), sent: sent, macVersion: "1.5.0", acked: PushAck())
    #expect(phone.status(acked: refusedFirst, macVersion: "1.5.0") == "推送登记无效")
    #expect(registrar(done: true).status(acked: refusedFirst, macVersion: "1.5.0") == "还没登记（要连上 Mac）")
    // Changed on the phone and not sent yet: not registered (until the next connection).
    #expect(registrar(done: true).status(acked: unready, macVersion: "1.5.0") == "还没登记（要连上 Mac）")
    // Notifications off in the system's settings: that comes first, it is what the user can do something about.
    #expect(registrar(notificationsAllowed: false).status(acked: quiet, macVersion: "1.5.0") == "通知被关掉了，去系统设置打开")
    // No device token yet.
    #expect(registrar(deviceToken: nil).status(acked: quiet, macVersion: "1.5.0") == "还没登记（要连上 Mac）")
}
