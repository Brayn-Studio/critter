import CritterClient
import CritterKit
import Foundation
import os
import Testing

// Answering from a notification's button while the app is in the background (spec §8.3, §8.7): one connection of its
// own, `hello`, `answer`, `result`, at most 20 seconds, then closed.

private let home = Endpoint(host: "192.168.1.20", port: 47823)
private let pin = String(repeating: "ab", count: 32)
private let pairing = StoredPairing(endpoint: home, fingerprint: pin, macName: "Mac", deviceId: "d1")
private let credentials = Credentials(deviceId: "d1", token: "t1")
private let allow = AnswerPayload(decision: "allow")

/// One background answer under way against `mac`, on `clock`.
private func answering(
    _ payload: AnswerPayload = allow, mac: FakeMac, clock: ManualClock
) -> Task<BackgroundAnswerResult, Never> {
    Task {
        await BackgroundAnswer.send(
            payload, requestId: "r1", pairing: pairing, credentials: credentials, transport: mac, app: "critter-ios/test",
            clock: clock.sleep
        )
    }
}

/// What `answer` came to, if it does within 2 s of real time (nil: it is still under way).
private func finished(_ answer: Task<BackgroundAnswerResult, Never>) async -> BackgroundAnswerResult? {
    let result = OSAllocatedUnfairLock<BackgroundAnswerResult?>(initialState: nil)
    let waiter = Task {
        let value = await answer.value
        result.withLock { $0 = value }
    }
    _ = await eventually { result.withLock { $0 } != nil }
    waiter.cancel()
    return result.withLock { $0 }
}

/// Reads the phone's `answer` and replies with `result`.
private func reply(_ mac: FakeMac, ok: Bool, reason: ResultReason? = nil, message: String? = nil) async throws {
    let frame = try #require(await mac.nextFrame())
    guard case .answer(let id?, let requestId, _) = frame else {
        Issue.record("expected an answer, got \(frame)")
        return
    }
    #expect(requestId == "r1")
    mac.send(.result(id: id, ok: ok, reason: reason, message: message))
}

@Suite(.timeLimit(.minutes(1)))
struct BackgroundAnswerTests {
    @Test func backgroundAnswerSendsAndCloses() async throws {
        let mac = FakeMac()
        mac.autoWelcome = "Mac"
        let clock = ManualClock()
        let answer = answering(mac: mac, clock: clock)
        // To the paired Mac, pinned to its certificate.
        #expect(try #require(await mac.nextFrame()) == .hello(protocolVersion: 1, deviceId: "d1", token: "t1", app: "critter-ios/test"))
        let frame = try #require(await mac.nextFrame())
        guard case .answer(let id?, "r1", allow) = frame else {
            Issue.record("expected the answer, got \(frame)")
            return
        }
        // The snapshot the Mac sends after `welcome` is not what is waited for.
        mac.send(.snapshot(seq: 1, sentAt: 1, body: emptySnapshot))
        mac.send(.result(id: "someone-else", ok: false, reason: .failed, message: nil))
        mac.send(.result(id: id, ok: true, reason: nil, message: nil))
        let result = await answer.value
        #expect(result == .answered(decision: "allow"))
        #expect(result.notificationText == NotificationResultText(title: "已允许", body: "", keepButtons: false))
        #expect(mac.connects == [FakeMac.Connect(host: home.host, port: home.port, fingerprint: pin)])
        #expect(await eventually { mac.openSockets == 0 })
        #expect(mac.received.count == 2)

        // A deny reads as such, with or without a reason.
        let denying = FakeMac()
        denying.autoWelcome = "Mac"
        let denied = answering(AnswerPayload(decision: "deny", message: "换个目录"), mac: denying, clock: ManualClock())
        _ = await denying.nextFrame()
        try await reply(denying, ok: true)
        #expect(await denied.value.notificationText == NotificationResultText(title: "已拒绝", body: "", keepButtons: false))
        #expect(await eventually { denying.openSockets == 0 })
    }

    @Test func backgroundAnswerGivesUpAfter20Seconds() async throws {
        // The Mac takes the connection and never says `welcome` (asleep, or another network in between).
        let mac = FakeMac()
        let clock = ManualClock()
        let answer = answering(mac: mac, clock: clock)
        _ = try #require(await mac.nextFrame())
        #expect(await clock.waitForSleepers(1))
        #expect(clock.asked == [.seconds(20)])
        clock.advance(by: .seconds(19))
        await settle()
        #expect(mac.openSockets == 1)
        clock.advance(by: .seconds(1))
        let result = await answer.value
        #expect(result == .unreachable)
        // The notification says so and keeps its buttons, for another try.
        #expect(result.notificationText == NotificationResultText(title: "没送到：连不上 Mac（要和电脑在同一个 Wi‑Fi）", body: "", keepButtons: true))
        #expect(await eventually { mac.openSockets == 0 })

        // A connection that is still being made at 20 s: given up at 20 s all the same, and closed once it is made.
        let slow = FakeMac()
        slow.connectDelay = .milliseconds(300)
        let slowClock = ManualClock()
        let slowAnswer = answering(mac: slow, clock: slowClock)
        #expect(await slowClock.waitForSleepers(1))
        slowClock.advance(by: .seconds(20))
        #expect(await slowAnswer.value == .unreachable)
        #expect(await eventually { slow.finishedConnects == 1 })
        #expect(await eventually { slow.openSockets == 0 })
        #expect(slow.received.isEmpty)

        // No connection at all: at once, the same.
        let away = FakeMac()
        away.failNextConnects(.unreachable)
        #expect(await answering(mac: away, clock: ManualClock()).value == .unreachable)

        // The connection drops before the result: it may or may not have arrived, so the buttons stay (a second try
        // gets "已在电脑上处理" if it did).
        let dropping = FakeMac()
        dropping.autoWelcome = "Mac"
        let dropped = answering(mac: dropping, clock: ManualClock())
        _ = await dropping.nextFrame()
        _ = await dropping.nextFrame()
        dropping.drop()
        #expect(await dropped.value == .unreachable)
    }

    @Test func aResolvedRequestReadsAsHandledElsewhere() async throws {
        let mac = FakeMac()
        mac.autoWelcome = "Mac"
        let answer = answering(mac: mac, clock: ManualClock())
        _ = await mac.nextFrame()
        try await reply(mac, ok: false, reason: .resolved, message: "已在电脑上处理")
        let result = await answer.value
        #expect(result == .resolved)
        // Never "已允许": the computer had it first.
        #expect(result.notificationText == NotificationResultText(title: "已在电脑上处理", body: "", keepButtons: false))
        #expect(await eventually { mac.openSockets == 0 })

        // Another phone was first: the same.
        let second = FakeMac()
        second.autoWelcome = "Mac"
        let late = answering(mac: second, clock: ManualClock())
        _ = await second.nextFrame()
        try await reply(second, ok: false, reason: .resolved, message: "已经有人回答过了")
        #expect(await late.value.notificationText.title == "已在电脑上处理")
    }

    @Test func anExpiredRequestSaysSo() async throws {
        let mac = FakeMac()
        mac.autoWelcome = "Mac"
        let answer = answering(mac: mac, clock: ManualClock())
        _ = await mac.nextFrame()
        try await reply(mac, ok: false, reason: .expired, message: "这个请求已经过期了")
        let result = await answer.value
        #expect(result == .expired)
        #expect(result.notificationText == NotificationResultText(title: "已经过期了", body: "", keepButtons: false))

        // Anything else the Mac says no to: its words, and the buttons stay where trying again can help.
        let failing = FakeMac()
        failing.autoWelcome = "Mac"
        let failed = answering(mac: failing, clock: ManualClock())
        _ = await failing.nextFrame()
        try await reply(failing, ok: false, reason: .failed, message: "提交失败")
        #expect(await failed.value.notificationText == NotificationResultText(title: "提交失败", body: "", keepButtons: true))
        let invalid = FakeMac()
        invalid.autoWelcome = "Mac"
        let refused = answering(mac: invalid, clock: ManualClock())
        _ = await invalid.nextFrame()
        try await reply(invalid, ok: false, reason: .invalid, message: nil)
        #expect(await refused.value.notificationText == NotificationResultText(title: "没有发送出去", body: "", keepButtons: false))

        // A Mac that no longer knows this phone.
        let revoked = FakeMac()
        let unknown = answering(mac: revoked, clock: ManualClock())
        _ = await revoked.nextFrame()
        revoked.send(.denied(reason: .badToken))
        #expect(await unknown.value.notificationText
            == NotificationResultText(title: "这台手机已不在电脑的配对列表里，请重新配对", body: "", keepButtons: false))
        #expect(await eventually { revoked.openSockets == 0 })
    }

    @Test func aCancelledAnswerEndsAtOnceAndCloses() async throws {
        // The system's background time runs out before the 20 s (the app's expiration handler cancels the task): the
        // answer ends now, as not delivered, and the connection is closed -- the app is not kept in the background.
        let mac = FakeMac()
        let clock = ManualClock()
        let answer = answering(mac: mac, clock: clock)
        _ = try #require(await mac.nextFrame())
        #expect(await clock.waitForSleepers(1))
        #expect(mac.openSockets == 1)
        answer.cancel()
        #expect(await finished(answer) == .unreachable)
        #expect(await eventually { mac.openSockets == 0 })
        // The 20 s wait is let go too.
        #expect(await clock.waitForSleepers(0))

        // Cancelled while the connection is still being made: ended at once, and the socket closed once it is made.
        let slow = FakeMac()
        slow.connectDelay = .milliseconds(300)
        let slowAnswer = answering(mac: slow, clock: ManualClock())
        #expect(await eventually { slow.connects.count == 1 })
        slowAnswer.cancel()
        #expect(await finished(slowAnswer) == .unreachable)
        #expect(await eventually { slow.finishedConnects == 1 })
        #expect(await eventually { slow.openSockets == 0 })
        #expect(slow.received.isEmpty)

        // Cancelled before it began: nothing is connected at all.
        let idle = FakeMac()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await BackgroundAnswer.send(
                allow, requestId: "r1", pairing: pairing, credentials: credentials, transport: idle,
                app: "critter-ios/test", clock: ManualClock().sleep
            )
        }
        #expect(await finished(cancelled) == .unreachable)
        await settle()
        #expect(idle.connects.isEmpty)
    }

    @Test func nothingIsSentBeforeWelcome() async throws {
        let mac = FakeMac()
        let clock = ManualClock()
        let answer = answering(mac: mac, clock: clock)
        guard case .hello = try #require(await mac.nextFrame()) else {
            Issue.record("the first frame is not a hello")
            return
        }
        // The Mac has not welcomed the phone: nothing but `hello` has gone out, also after a frame that is not `welcome`.
        mac.send(.snapshot(seq: 1, sentAt: 1, body: emptySnapshot))
        await settle()
        #expect(mac.received.count == 1)
        mac.send(.welcome(macName: "Mac", version: "1.5.0"))
        try await reply(mac, ok: true)
        #expect(await answer.value == .answered(decision: "allow"))
    }
}
