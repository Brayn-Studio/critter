import Foundation
import Testing
@testable import CritterCore

// The parts of the Mac's `PushCoordinator` that need no queue, clock or network: when push is on at all
// (`PushCoordinatorRules`), and what each registered iPhone is sent for a snapshot (`PushFanout`).

private let t0: Int64 = 1_760_000_000_000
private let bundle = APNsConfig.defaultBundleId
private let keyA = PushCrypto.makeKey()
private let keyB = PushCrypto.makeKey()

private func session(_ id: String, _ state: PetState = .idle) -> BridgeSession {
    BridgeSession(
        id: id, name: id, source: .terminal, state: state, cwd: "/Users/me/proj", skin: "sprig",
        eventTime: 1, startedAt: 1, tracked: true
    )
}

private func pending(_ requestId: String, _ sessionId: String) -> BridgePending {
    BridgePending(
        requestId: requestId, sessionId: sessionId, kind: .permission, toolName: "Bash", summary: "ls",
        input: .null, createdAt: 1, expiresAt: nil
    )
}

private func body(_ sessions: [BridgeSession], _ pending: [BridgePending] = []) -> SnapshotBody {
    SnapshotBody(
        sessions: sessions, pending: pending,
        prefs: BridgePrefs(skin: "sprig", randomSkins: false, idleDim: 1.0, mergeThreshold: 4, soundTheme: "pixel")
    )
}

private func registration(
    _ token: String, key: String = keyA, environment: PushEnvironment = .sandbox, done: Bool = false,
    activity: ActivityRegistration? = nil, bundleId: String = bundle
) -> PushRegistration {
    PushRegistration(
        token: token, environment: environment, bundleId: bundleId, key: key, notifyDone: done, notifyError: false,
        activity: activity
    )
}

private func record(_ id: String, _ push: PushRegistration?) -> DeviceRecord {
    DeviceRecord(id: id, name: "phone \(id)", tokenHash: "hash", pairedAt: 1, push: push)
}

private func fanout(_ records: [DeviceRecord]) -> PushFanout {
    let fanout = PushFanout()
    fanout.bundleId = bundle
    fanout.sync(records)
    return fanout
}

private func json(_ push: OutgoingPush) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: push.message.payload) as? [String: Any]) ?? [:]
}

/// What the alert pushes to `deviceId` are about: a request's id, or "<category>:<session id>".
private func alerts(_ pushes: [OutgoingPush], to deviceId: String) -> [String] {
    pushes.filter { $0.target.deviceId == deviceId && $0.message.pushType == .alert }.map { push in
        let object = json(push)
        return object["r"] as? String ?? "\(object["k"] as? String ?? "?"):\(object["s"] as? String ?? "?")"
    }
}

/// The notification ids withdrawn from `deviceId`, one list per background push.
private func withdrawals(_ pushes: [OutgoingPush], to deviceId: String) -> [[String]] {
    pushes.filter { $0.target.deviceId == deviceId && $0.message.pushType == .background }.map { json($0)["w"] as? [String] ?? [] }
}

private func liveEvents(_ pushes: [OutgoingPush]) -> [String] {
    pushes.filter { $0.message.pushType == .liveActivity }.map { push in
        let aps = json(push)["aps"] as? [String: Any]
        return "\(aps?["event"] as? String ?? "?")>\(push.target.kind.rawValue):\(push.target.token)"
    }
}

private func target(_ deviceId: String, _ kind: PushTarget.Kind, _ token: String) -> PushTarget {
    PushTarget(deviceId: deviceId, kind: kind, token: token, environment: .sandbox)
}

// MARK: - When push runs at all

@Test func nothingRunsWithoutPushConfigured() {
    // No phone connected and push not on: `changed()` assembles nothing (no snapshot, so no timer and no request).
    #expect(!PushCoordinatorRules.shouldAssemble(hasReadyClients: false, pushActive: false))
    // A connected phone gets its snapshots as before; push alone is enough too.
    #expect(PushCoordinatorRules.shouldAssemble(hasReadyClients: true, pushActive: false))
    #expect(PushCoordinatorRules.shouldAssemble(hasReadyClients: false, pushActive: true))

    // Push is not on without a working setup, or without a device that registered.
    #expect(!PushCoordinatorRules.isActive(bridgeOn: true, configReady: false, blocked: false, reachableDevices: 2))
    #expect(!PushCoordinatorRules.isActive(bridgeOn: true, configReady: true, blocked: false, reachableDevices: 0))

    // Paired phones that never registered for push give the fan-out nothing to do, now or later.
    let idle = fanout([record("android", nil), record("iphone", nil)])
    #expect(idle.reachableDevices == 0)
    #expect(idle.snapshot(body([session("s1", .waiting)], [pending("r1", "s1")]), now: t0).isEmpty)
    #expect(idle.snapshot(body([session("s1", .done)]), now: t0 + 1000).isEmpty)
    #expect(idle.deadline(now: t0 + 60_000).isEmpty)
    #expect(idle.nextDeadline() == nil)
    #expect(idle.endAll(now: t0).isEmpty)
    #expect(idle.test().isEmpty)
}

@Test func pushIsActiveOnlyWithTheBridgeOnAWorkingSetupAndARegisteredDevice() {
    for bridgeOn in [false, true] {
        for configReady in [false, true] {
            for blocked in [false, true] {
                for devices in [0, 1, 3] {
                    let active = PushCoordinatorRules.isActive(
                        bridgeOn: bridgeOn, configReady: configReady, blocked: blocked, reachableDevices: devices
                    )
                    #expect(active == (bridgeOn && configReady && !blocked && devices > 0))
                }
            }
        }
    }
}

@Test func onlyDevicesOfTheConfiguredAppCount() {
    let other = registration("cc", bundleId: "com.example.other")
    let mixed = fanout([record("a", registration("aa")), record("b", other), record("c", nil)])
    #expect(mixed.reachableDevices == 1)
    let pushes = mixed.snapshot(body([session("s1")]), now: t0) + mixed.snapshot(
        body([session("s1", .waiting)], [pending("r1", "s1")]), now: t0 + 1
    )
    #expect(alerts(pushes, to: "a") == ["r1"])
    #expect(pushes.allSatisfy { $0.target.deviceId == "a" })

    // Without a setup there is no app to push to.
    mixed.bundleId = nil
    #expect(mixed.reachableDevices == 0)
    #expect(mixed.snapshot(body([session("s1", .waiting)], [pending("r2", "s1")]), now: t0 + 2).isEmpty)
}

@Test func theDestinationDecidesWhetherARegistrationStartsOver() {
    let base = registration("aa", done: false, activity: ActivityRegistration(enabled: true, startToken: "51"))
    #expect(PushCoordinatorRules.startsOver(from: nil, to: base))
    #expect(!PushCoordinatorRules.startsOver(from: base, to: base))
    var prefs = base
    prefs.notifyDone = true
    prefs.notifyError = true
    #expect(!PushCoordinatorRules.startsOver(from: base, to: prefs))
    var activity = base
    activity.activity = ActivityRegistration(enabled: true, startToken: "52", activityId: "A", activityToken: "a1")
    #expect(!PushCoordinatorRules.startsOver(from: base, to: activity))
    for change in [
        registration("bb", activity: base.activity), registration("aa", key: keyB, activity: base.activity),
        registration("aa", environment: .production, activity: base.activity),
        registration("aa", activity: base.activity, bundleId: "com.example.other"),
    ] {
        #expect(PushCoordinatorRules.startsOver(from: base, to: change))
    }
}

// MARK: - New and changed registrations

@Test func aNewlyRegisteredDeviceStartsOver() {
    let pushes = fanout([record("a", registration("aa"))])
    _ = pushes.snapshot(body([session("s1")]), now: t0)

    pushes.sync([record("a", registration("aa")), record("b", registration("bb", key: keyB))])
    let first = pushes.snapshot(body([session("s1", .waiting)], [pending("r1", "s1")]), now: t0 + 1)
    #expect(alerts(first, to: "a") == ["r1"])
    // b's first snapshot is the past: it only records.
    #expect(first.allSatisfy { $0.target.deviceId == "a" })

    let second = pushes.snapshot(body([session("s1", .waiting)], [pending("r1", "s1"), pending("r2", "s1")]), now: t0 + 2)
    #expect(alerts(second, to: "a") == ["r2"])
    #expect(alerts(second, to: "b") == ["r2"])
}

@Test func aChangedDestinationStartsOverButNewPrefsAndActivityTokensDoNot() {
    let pushes = fanout([record("a", registration("aa"))])
    _ = pushes.snapshot(body([session("s1")]), now: t0)

    // Done notifications switched on: the tracker carries on, with the new prefs.
    pushes.sync([record("a", registration("aa", done: true))])
    #expect(alerts(pushes.snapshot(body([session("s1", .done)]), now: t0 + 1), to: "a") == ["done:s1"])

    // The Live Activity part changed: still the same tracker.
    let withActivity = registration("aa", done: true, activity: ActivityRegistration(enabled: false))
    pushes.sync([record("a", withActivity)])
    let next = pushes.snapshot(body([session("s1", .waiting)], [pending("r1", "s1")]), now: t0 + 2)
    #expect(alerts(next, to: "a") == ["r1"])
    #expect(withdrawals(next, to: "a") == [["done:s1"]])

    // A new token (the app was reinstalled): it starts over, and the next snapshot only records.
    pushes.sync([record("a", registration("cc", done: true))])
    #expect(pushes.snapshot(body([session("s1", .waiting)], [pending("r1", "s1"), pending("r2", "s1")]), now: t0 + 3).isEmpty)
    let after = pushes.snapshot(
        body([session("s1", .waiting)], [pending("r1", "s1"), pending("r2", "s1"), pending("r3", "s1")]), now: t0 + 4
    )
    #expect(alerts(after, to: "a") == ["r3"])
    #expect(after.allSatisfy { $0.target.token == "cc" })
}

@Test func startingOverForgetsWhatEveryDeviceSaw() {
    let pushes = fanout([record("a", registration("aa")), record("b", registration("bb", key: keyB))])
    _ = pushes.snapshot(body([session("s1")]), now: t0)
    // The setup changed (or the bridge was switched on again).
    pushes.startOver()
    #expect(pushes.snapshot(body([session("s1", .waiting)], [pending("r1", "s1")]), now: t0 + 1).isEmpty)
    let next = pushes.snapshot(body([session("s1", .waiting)], [pending("r1", "s1"), pending("r2", "s1")]), now: t0 + 2)
    #expect(alerts(next, to: "a") == ["r2"])
    #expect(alerts(next, to: "b") == ["r2"])
}

@Test func aDeviceThatGoesAwayIsForgotten() {
    let pushes = fanout([record("a", registration("aa")), record("b", registration("bb", key: keyB))])
    _ = pushes.snapshot(body([session("s1")]), now: t0)
    // b took its registration back.
    pushes.sync([record("a", registration("aa")), record("b", nil)])
    #expect(pushes.reachableDevices == 1)
    #expect(pushes.registration("b") == nil)
    let next = pushes.snapshot(body([session("s1", .waiting)], [pending("r1", "s1")]), now: t0 + 1)
    #expect(next.allSatisfy { $0.target.deviceId == "a" })
    // Registering again is a new registration.
    pushes.sync([record("a", registration("aa")), record("b", registration("bb", key: keyB))])
    let again = pushes.snapshot(body([session("s1", .waiting)], [pending("r1", "s1"), pending("r2", "s1")]), now: t0 + 2)
    #expect(alerts(again, to: "b").isEmpty)
}

// MARK: - What goes where

@Test func eachDeviceGetsItsOwnSealedPushesAtItsOwnToken() throws {
    let pushes = fanout([
        record("a", registration("aa", key: keyA)),
        record("b", registration("bb", key: keyB, environment: .production)),
    ])
    _ = pushes.snapshot(body([session("s1")]), now: t0)
    let sent = pushes.snapshot(body([session("s1", .waiting)], [pending("r1", "s1")]), now: t0 + 1)
    #expect(sent.map(\.target) == [target("a", .device, "aa"), PushTarget(deviceId: "b", kind: .device, token: "bb", environment: .production)])
    for (push, key, otherKey) in [(sent[0], keyA, keyB), (sent[1], keyB, keyA)] {
        guard case .alert(let alert)? = PushPayload.parse(json(push)) else {
            Issue.record("not an alert")
            continue
        }
        #expect(try PushCrypto.open(alert, key: key).title.contains("s1"))
        #expect(throws: (any Error).self) { try PushCrypto.open(alert, key: otherKey) }
    }
}

@Test func withdrawalsGoOutTogetherBeforeNewNotifications() {
    let pushes = fanout([record("a", registration("aa", done: true))])
    _ = pushes.snapshot(body([session("s1"), session("s2")]), now: t0)
    _ = pushes.snapshot(body([session("s1", .waiting), session("s2", .waiting)], [pending("r1", "s1"), pending("r2", "s2")]), now: t0 + 1)
    // Both answered at once, and s1 finished.
    let next = pushes.snapshot(body([session("s1", .done), session("s2", .running)]), now: t0 + 2)
    #expect(withdrawals(next, to: "a") == [["r1", "r2"]])
    #expect(alerts(next, to: "a") == ["done:s1"])
    #expect(next.first?.message.pushType == .background)
}

@Test func liveActivityPushesGoToTheStartAndActivityTokens() {
    let start = ActivityRegistration(enabled: true, startToken: "5151")
    let pushes = fanout([record("a", registration("aa", activity: start))])
    // Push-to-start, with the start token.
    #expect(liveEvents(pushes.snapshot(body([session("s1", .running)]), now: t0)) == ["start>activityStart:5151"])

    // The phone reports the new activity's token; more waiting is sent at once, to that token.
    let running = ActivityRegistration(enabled: true, startToken: "5151", activityId: "A1", activityToken: "a1a1")
    pushes.sync([record("a", registration("aa", activity: running))])
    let waiting = pushes.snapshot(body([session("s1", .waiting)]), now: t0 + 1000)
    #expect(liveEvents(waiting) == ["update>activity:a1a1"])
    #expect(waiting.first { $0.message.pushType == .liveActivity }?.message.priority == 10)
    // The waiting notice still goes to the device token.
    #expect(alerts(waiting, to: "a") == ["waitingElsewhere:s1"])
    #expect(waiting.filter { $0.message.pushType == .alert }.allSatisfy { $0.target == target("a", .device, "aa") })

    // Live Activity switched off on the phone: it is ended.
    pushes.sync([record("a", registration("aa", activity: ActivityRegistration(enabled: false, activityToken: "a1a1")))])
    #expect(liveEvents(pushes.snapshot(body([session("s1", .waiting)]), now: t0 + 2000)) == ["end>activity:a1a1"])
}

@Test func aThrottledUpdateIsSentWhenItsDeadlineComes() {
    let app = ActivityRegistration(enabled: true, startToken: "5151", activityId: "A1", activityToken: "a1a1")
    let pushes = fanout([record("a", registration("aa", activity: app))])
    // An activity the app started: the Mac says what is true now.
    #expect(liveEvents(pushes.snapshot(body([session("s1", .running)]), now: t0)) == ["update>activity:a1a1"])
    #expect(pushes.nextDeadline() == t0 + LiveActivityPlanner.maxAge)

    // A change within 10 s waits for the end of the throttle period.
    #expect(liveEvents(pushes.snapshot(body([session("s1", .done)]), now: t0 + 2000)).isEmpty)
    #expect(pushes.nextDeadline() == t0 + LiveActivityPlanner.throttle)
    #expect(pushes.deadline(now: t0 + 5000).isEmpty)
    let due = pushes.deadline(now: t0 + LiveActivityPlanner.throttle)
    #expect(liveEvents(due) == ["update>activity:a1a1"])
    let state = (json(due[0])["aps"] as? [String: Any])?["content-state"] as? [String: Any]
    #expect((state?["lead"] as? [String: Any])?["state"] as? String == "done")
    #expect(pushes.nextDeadline() == t0 + LiveActivityPlanner.maxAge)
}

// MARK: - Taking things back

@Test func aRevokedDeviceHasItsActivityEndedThenItIsForgotten() {
    let app = ActivityRegistration(enabled: true, startToken: "5151", activityId: "A1", activityToken: "a1a1")
    let pushes = fanout([record("a", registration("aa", activity: app)), record("b", registration("bb", key: keyB))])
    _ = pushes.snapshot(body([session("s1", .running)]), now: t0)
    #expect(liveEvents(pushes.remove("a", now: t0 + 1000)) == ["end>activity:a1a1"])
    #expect(pushes.remove("a", now: t0 + 2000).isEmpty)
    #expect(pushes.registration("a") == nil)
    // A device without an activity has nothing to end.
    #expect(pushes.remove("b", now: t0 + 3000).isEmpty)
    #expect(pushes.snapshot(body([session("s1", .waiting)], [pending("r1", "s1")]), now: t0 + 4000).isEmpty)
}

@Test func switchingTheBridgeOffEndsEveryActivity() {
    let app = ActivityRegistration(enabled: true, activityId: "A1", activityToken: "a1a1")
    let pushes = fanout([
        record("a", registration("aa", activity: app)), record("b", registration("bb", key: keyB)),
        record("c", registration("cc", activity: ActivityRegistration(enabled: true, activityToken: "c1c1"), bundleId: "com.example.other")),
    ])
    _ = pushes.snapshot(body([session("s1", .running)]), now: t0)
    #expect(liveEvents(pushes.endAll(now: t0 + 1000)) == ["end>activity:a1a1"])
    #expect(pushes.endAll(now: t0 + 2000).isEmpty)
}

@Test func aGoneTokenIsDroppedOnlyWhileItIsStillTheCurrentOne() {
    let app = ActivityRegistration(enabled: true, startToken: "5151", activityId: "A1", activityToken: "a1a1")
    let pushes = fanout([record("a", registration("aa", activity: app))])
    #expect(pushes.tokenGone(target("a", .device, "aa")) == .dropRegistration)
    #expect(pushes.tokenGone(target("a", .device, "0ld")) == .ignore)
    #expect(pushes.tokenGone(target("a", .activity, "a1a1")) == .clearActivity)
    #expect(pushes.tokenGone(target("a", .activity, "0ld")) == .ignore)
    #expect(pushes.tokenGone(target("nobody", .device, "aa")) == .ignore)
    #expect(pushes.tokenGone(target("a", .activityStart, "5151")) == .ignore)
}

@Test func aGoneStartTokenIsNotUsedAgainUntilANewOneComes() {
    let start = ActivityRegistration(enabled: true, startToken: "5151")
    let pushes = fanout([record("a", registration("aa", activity: start))])
    #expect(liveEvents(pushes.snapshot(body([session("s1", .running)]), now: t0)) == ["start>activityStart:5151"])
    _ = pushes.tokenGone(target("a", .activityStart, "5151"))
    // No activity came of it: nothing to wait for, and the record lets the start go.
    #expect(pushes.takeRegistryEdits() == [.unconfirmedActivityStart(deviceId: "a", at: t0), .unconfirmedActivityStart(deviceId: "a", at: nil)])

    // The sessions go and the 5 minutes pass: the Mac no longer believes in that activity.
    _ = pushes.snapshot(body([]), now: t0 + 1000)
    _ = pushes.deadline(now: t0 + 1000 + LiveActivityPlanner.endAfterEmpty)
    // A session again: no start with the token APNs refused.
    #expect(liveEvents(pushes.snapshot(body([session("s1", .running)]), now: t0 + 20 * 60_000)).isEmpty)

    // The phone registers a new start token.
    pushes.sync([record("a", registration("aa", activity: ActivityRegistration(enabled: true, startToken: "6161")))])
    #expect(liveEvents(pushes.snapshot(body([session("s1", .running)]), now: t0 + 21 * 60_000)) == ["start>activityStart:6161"])
}

@Test func aTestPushGoesToEveryRegisteredDevice() throws {
    let pushes = fanout([
        record("a", registration("aa", key: keyA)), record("b", registration("bb", key: keyB)), record("c", nil),
        record("d", registration("dd", bundleId: "com.example.other")),
    ])
    let tests = pushes.test()
    #expect(tests.map(\.target) == [target("a", .device, "aa"), target("b", .device, "bb")])
    #expect(tests.allSatisfy { json($0)["k"] as? String == PushCategory.test.rawValue })
    guard case .alert(let alert)? = PushPayload.parse(json(tests[1])) else {
        Issue.record("not an alert")
        return
    }
    #expect(try PushCrypto.open(alert, key: keyB) == PushText(title: "Critter 推送测试", subtitle: "", body: "能看到这条，说明推送通了"))
}

@Test func aTokenUnderTwoDevicesIsPushedOnceToTheNewerPairing() {
    // A devices file from before the registry kept tokens apart: the same phone under two pairings.
    let pushes = fanout([record("old", registration("aa")), record("new", registration("aa", key: keyB)), record("c", registration("cc"))])
    #expect(pushes.reachableDevices == 2)
    _ = pushes.snapshot(body([session("s1")]), now: t0)
    let sent = pushes.snapshot(body([session("s1", .waiting)], [pending("r1", "s1")]), now: t0 + 1)
    #expect(sent.map(\.target.deviceId) == ["c", "new"])
}

private func timestamps(_ pushes: [OutgoingPush]) -> [Int] {
    pushes.filter { $0.message.pushType == .liveActivity }.compactMap { (json($0)["aps"] as? [String: Any])?["timestamp"] as? Int }
}

@Test func aStartWaitingForItsTokenIsKeptInTheRegistryAcrossARestart() {
    let start = ActivityRegistration(enabled: true, startToken: "5151")
    let pushes = fanout([record("a", registration("aa", activity: start))])
    #expect(liveEvents(pushes.snapshot(body([session("s1", .running)]), now: t0)) == ["start>activityStart:5151"])
    #expect(pushes.takeRegistryEdits() == [.unconfirmedActivityStart(deviceId: "a", at: t0)])
    #expect(pushes.takeRegistryEdits().isEmpty)

    // Critter restarts with the record that kept it: no second activity, even after the sessions go and come back.
    var kept = record("a", registration("aa", activity: start))
    kept.unconfirmedActivityStart = t0
    let restarted = fanout([kept])
    #expect(restarted.takeRegistryEdits().isEmpty)
    #expect(liveEvents(restarted.snapshot(body([session("s1", .running)]), now: t0 + 30 * 60_000)).isEmpty)
    _ = restarted.snapshot(body([]), now: t0 + 31 * 60_000)
    _ = restarted.deadline(now: t0 + 37 * 60_000)
    #expect(liveEvents(restarted.snapshot(body([session("s1", .running)]), now: t0 + 50 * 60_000)).isEmpty)

    // Its token arrives: the start is confirmed, and the record lets it go.
    let running = ActivityRegistration(enabled: true, startToken: "5151", activityId: "A1", activityToken: "a1a1")
    var reported = record("a", registration("aa", activity: running))
    reported.unconfirmedActivityStart = t0
    restarted.sync([reported])
    #expect(liveEvents(restarted.snapshot(body([session("s1", .running)]), now: t0 + 51 * 60_000)) == ["update>activity:a1a1"])
    #expect(restarted.takeRegistryEdits() == [.unconfirmedActivityStart(deviceId: "a", at: nil)])

    // A new destination starts from nothing, and the record forgets the start too.
    kept.push = registration("bb", activity: start)
    restarted.sync([kept])
    #expect(restarted.takeRegistryEdits() == [.unconfirmedActivityStart(deviceId: "a", at: nil)])
}

@Test func anEndForgetsTheActivityTokenAndTheSameTokenAgainIsIgnored() {
    let running = ActivityRegistration(enabled: true, startToken: "5151", activityId: "A1", activityToken: "a1a1")
    let pushes = fanout([record("a", registration("aa", activity: running))])
    #expect(liveEvents(pushes.snapshot(body([session("s1", .running)]), now: t0)) == ["update>activity:a1a1"])
    _ = pushes.snapshot(body([]), now: t0 + 1000)
    #expect(liveEvents(pushes.deadline(now: t0 + 1000 + LiveActivityPlanner.endAfterEmpty)) == ["end>activity:a1a1"])
    #expect(pushes.takeRegistryEdits() == [.clearActivity(deviceId: "a")])
    #expect(pushes.registration("a")?.activity?.activityToken == nil)

    // An old registration brings the token back: it stands for no activity, so a new one is started instead.
    pushes.sync([record("a", registration("aa", activity: running))])
    #expect(liveEvents(pushes.snapshot(body([session("s1", .waiting)]), now: t0 + 20 * 60_000)) == ["start>activityStart:5151"])

    // Revoking: the record goes, nothing is asked to be kept for it.
    _ = pushes.takeRegistryEdits()
    pushes.sync([record("a", registration("aa", activity: ActivityRegistration(enabled: true, startToken: "5151", activityToken: "b2b2")))])
    _ = pushes.snapshot(body([session("s1", .waiting)]), now: t0 + 21 * 60_000)
    _ = pushes.takeRegistryEdits()
    #expect(liveEvents(pushes.remove("a", now: t0 + 22 * 60_000)) == ["end>activity:b2b2"])
    #expect(pushes.takeRegistryEdits().isEmpty)
}

@Test func liveActivityTimestampsOnlyGoUp() {
    let start = ActivityRegistration(enabled: true, startToken: "5151")
    let pushes = fanout([record("a", registration("aa", activity: start))])
    let second = Int(t0 / 1000)
    #expect(timestamps(pushes.snapshot(body([session("s1", .running)]), now: t0)) == [second])
    pushes.sync([record("a", registration("aa", activity: ActivityRegistration(enabled: true, startToken: "5151", activityToken: "a1a1")))])
    // More waiting in the same second: sent at once, a second later on its stamp.
    #expect(timestamps(pushes.snapshot(body([session("s1", .waiting)]), now: t0 + 300)) == [second + 1])
    // A clock that steps back does not take it back either.
    #expect(timestamps(pushes.snapshot(body([session("s1", .waiting), session("s2", .waiting)]), now: t0 - 5000)) == [second + 2])
    // The end and the next start of the 7.5-hour restart get one each.
    let restart = t0 + LiveActivityPlanner.maxAge
    let pair = pushes.snapshot(body([session("s1", .waiting), session("s2", .waiting)]), now: restart)
    #expect(liveEvents(pair) == ["end>activity:a1a1", "start>activityStart:5151"])
    #expect(timestamps(pair) == [Int(restart / 1000), Int(restart / 1000) + 1])
}

// MARK: - Keeping the registry

/// A devices file in memory. `writable` false: it never takes a write (the disk is full, say), says so, and stays
/// as it was.
private final class FakeRegistry: PushRegistryWriting {
    private(set) var records: [DeviceRecord]
    let writable: Bool
    private(set) var writes = 0

    init(_ records: [DeviceRecord], writable: Bool) {
        self.records = records
        self.writable = writable
    }

    func setActivity(deviceId: String, activityId: String?, activityToken: String?) -> Bool {
        write(deviceId) {
            $0.push?.activity?.activityId = activityId
            $0.push?.activity?.activityToken = activityToken
        }
    }

    func setUnconfirmedActivityStart(deviceId: String, at time: Int64?) -> Bool {
        write(deviceId) { $0.unconfirmedActivityStart = time }
    }

    func dropPushToken(deviceId: String) -> Bool {
        write(deviceId) {
            $0.push = nil
            $0.unconfirmedActivityStart = nil
        }
    }

    private func write(_ deviceId: String, _ edit: (inout DeviceRecord) -> Void) -> Bool {
        writes += 1
        guard writable else { return false }
        for i in records.indices where records[i].id == deviceId { edit(&records[i]) }
        return true
    }
}

/// `PushCoordinator` and `BridgeController` as they are wired: edits are kept with `PushRegistryEdits.keep`, and
/// a registry that changed is read again (`refreshDevices`) and handed to the fan-out (`devicesChanged`), which
/// keeps what that asks for in turn. `refreshes` counts the reads; past `limit` it stops, so a loop fails the test
/// instead of overflowing the stack.
private final class RegistryLoop {
    let fanout: PushFanout
    let registry: FakeRegistry
    private(set) var refreshes = 0
    private(set) var logs: [String] = []
    let limit = 20

    init(_ fanout: PushFanout, _ registry: FakeRegistry) {
        self.fanout = fanout
        self.registry = registry
    }

    func keepEdits() {
        PushRegistryEdits.keep(fanout.takeRegistryEdits(), in: registry, log: { self.logs.append($0) }) { self.devicesChanged() }
    }

    func devicesChanged() {
        refreshes += 1
        guard refreshes <= limit else { return }
        fanout.sync(registry.records)
        keepEdits()
    }
}

@Test func aDevicesFileThatCannotBeWrittenDoesNotLoop() {
    let start = ActivityRegistration(enabled: true, startToken: "5151")
    let records = [record("a", registration("aa", activity: start))]
    let loop = RegistryLoop(fanout(records), FakeRegistry(records, writable: false))
    // A push-to-start: the Mac asks to keep it while its token is on the way, and the write fails.
    #expect(liveEvents(loop.fanout.snapshot(body([session("s1", .running)]), now: t0)) == ["start>activityStart:5151"])
    loop.keepEdits()
    #expect(loop.refreshes == 0)
    #expect(loop.registry.writes == 1)
    #expect(loop.logs.count == 1)

    // The next change of the device list (a `lastSeen`, say) brings back what the file still says: the fan-out asks
    // once more, the write fails once more, and that is all.
    loop.devicesChanged()
    #expect(loop.refreshes == 1)
    #expect(loop.registry.writes == 2)
    // The start is still held off meanwhile: no second activity.
    #expect(liveEvents(loop.fanout.snapshot(body([session("s1", .waiting)]), now: t0 + 20 * 60_000)).isEmpty)
}

@Test func aWrittenEditReadsTheDevicesOnceMore() {
    let start = ActivityRegistration(enabled: true, startToken: "5151")
    let records = [record("a", registration("aa", activity: start))]
    let loop = RegistryLoop(fanout(records), FakeRegistry(records, writable: true))
    _ = loop.fanout.snapshot(body([session("s1", .running)]), now: t0)
    loop.keepEdits()
    // Written: the list is read again, and it now says what the fan-out asked for, so nothing more is asked.
    #expect(loop.refreshes == 1)
    #expect(loop.registry.writes == 1)
    #expect(loop.registry.records.first?.unconfirmedActivityStart == t0)
    #expect(loop.logs.isEmpty)
    // Nothing to keep: nothing is read.
    loop.keepEdits()
    #expect(loop.refreshes == 1)
}

@Test func aStartThatWentNowhereIsLetGoAndKeptAtOnce() {
    let start = ActivityRegistration(enabled: true, startToken: "5151")
    for failure in [APNsOutcome.configError("密钥或 Team ID 不对"), .rejected("network error"), .rejected("signing")] {
        let pushes = fanout([record("a", registration("aa", activity: start))])
        #expect(liveEvents(pushes.snapshot(body([session("s1", .running)]), now: t0)) == ["start>activityStart:5151"])
        #expect(pushes.takeRegistryEdits() == [.unconfirmedActivityStart(deviceId: "a", at: t0)])
        // No activity came of it: the record lets the start go now, not with the next snapshot.
        pushes.delivered(failure, to: target("a", .activityStart, "5151"))
        #expect(pushes.takeRegistryEdits() == [.unconfirmedActivityStart(deviceId: "a", at: nil)], Comment(rawValue: "\(failure)"))
        // The token is fine: it starts again, after the usual ten minutes rather than 8 hours.
        #expect(liveEvents(pushes.snapshot(body([session("s1", .waiting)]), now: t0 + 60_000)).isEmpty)
        #expect(liveEvents(pushes.snapshot(body([session("s1", .running)]), now: t0 + 10 * 60_000)) == ["start>activityStart:5151"])
    }

    // A start APNs took goes on waiting for its token; another device's failures change nothing here.
    let pushes = fanout([record("a", registration("aa", activity: start))])
    _ = pushes.snapshot(body([session("s1", .running)]), now: t0)
    _ = pushes.takeRegistryEdits()
    pushes.delivered(.sent, to: target("a", .activityStart, "5151"))
    pushes.delivered(.rejected("network error"), to: target("b", .activityStart, "5151"))
    pushes.delivered(.rejected("network error"), to: target("a", .device, "aa"))
    #expect(pushes.takeRegistryEdits().isEmpty)
    #expect(liveEvents(pushes.snapshot(body([session("s1", .waiting)]), now: t0 + 20 * 60_000)).isEmpty)
}

@Test func aGoneTokenIsKeptInTheRegistryAtOnce() {
    let app = ActivityRegistration(enabled: true, startToken: "5151", activityId: "A1", activityToken: "a1a1")
    let pushes = fanout([record("a", registration("aa", activity: app)), record("b", registration("bb", key: keyB))])
    _ = pushes.snapshot(body([session("s1", .running)]), now: t0)
    _ = pushes.takeRegistryEdits()

    // The activity's token: forgotten here and in the record.
    pushes.delivered(.dropToken, to: target("a", .activity, "a1a1"))
    #expect(pushes.takeRegistryEdits() == [.clearActivity(deviceId: "a")])
    #expect(pushes.registration("a")?.activity?.activityToken == nil)
    // An old token says nothing about the current one.
    pushes.delivered(.dropToken, to: target("b", .device, "0ld"))
    #expect(pushes.takeRegistryEdits().isEmpty)
    // The device token: the whole registration goes, here at once and from the record.
    pushes.delivered(.dropToken, to: target("b", .device, "bb"))
    #expect(pushes.takeRegistryEdits() == [.dropRegistration(deviceId: "b")])
    #expect(pushes.registration("b") == nil)
    #expect(alerts(pushes.snapshot(body([session("s1", .waiting)], [pending("r1", "s1")]), now: t0 + 1000), to: "b").isEmpty)
    // A refused start token lets the start go in the record too.
    let starting = fanout([record("c", registration("cc", activity: ActivityRegistration(enabled: true, startToken: "6161")))])
    _ = starting.snapshot(body([session("s1", .running)]), now: t0)
    _ = starting.takeRegistryEdits()
    starting.delivered(.dropToken, to: target("c", .activityStart, "6161"))
    #expect(starting.takeRegistryEdits() == [.unconfirmedActivityStart(deviceId: "c", at: nil)])
}

@Test func droppingARegistrationIsWrittenToTheRegistry() {
    let records = [record("a", registration("aa"))]
    let registry = FakeRegistry(records, writable: true)
    var changes = 0
    PushRegistryEdits.keep([.dropRegistration(deviceId: "a")], in: registry, log: { _ in }) { changes += 1 }
    #expect(registry.records.first?.push == nil)
    #expect(changes == 1)
}

@Test func switchingTheBridgeOffLetsAStartWaitingForItsTokenGo() {
    let start = ActivityRegistration(enabled: true, startToken: "5151")
    let pushes = fanout([record("a", registration("aa", activity: start))])
    _ = pushes.snapshot(body([session("s1", .running)]), now: t0)
    _ = pushes.takeRegistryEdits()
    // Nothing to end without a token, but the start is let go: the doc's list of what releases it says so.
    #expect(pushes.endAll(now: t0 + 1000).isEmpty)
    #expect(pushes.takeRegistryEdits() == [.unconfirmedActivityStart(deviceId: "a", at: nil)])
}
