import CritterClient
import CritterKit
import Foundation
import Testing

private let home = Endpoint(host: "192.168.1.20", port: 47823)
private let pin = String(repeating: "ab", count: 32)
private let credentials = Credentials(deviceId: "d1", token: "t1")

/// A client wired to a `FakeMac`, with its events and backoff sleeps recorded.
private struct Rig {
    let mac = FakeMac()
    let events = EventLog()
    let resolver = FixedResolver(home)
    let sleeper: Sleeper
    let client: BridgeClient

    init(
        sleeper: Sleeper = Sleeper(), credentials: Credentials? = credentials,
        requestTimeout: Duration = .seconds(10), pingInterval: Duration = .seconds(60)
    ) {
        self.sleeper = sleeper
        client = BridgeClient(
            transport: mac, endpoint: resolver, fingerprint: pin,
            credentials: { credentials }, app: "critter-ios/test",
            onEvent: events.record,
            requestTimeout: requestTimeout, pingInterval: pingInterval, sleep: sleeper.sleep
        )
    }

    /// Starts the client, and has the Mac welcome its hello.
    func connect() async throws {
        await client.start()
        try await welcomeNextHello()
    }

    /// Reads the phone's hello on a new connection and welcomes it.
    func welcomeNextHello() async throws {
        let hello = try #require(await mac.nextFrame())
        guard case .hello = hello else {
            Issue.record("expected a hello, got \(hello)")
            return
        }
        mac.send(.welcome(macName: "Mac", version: "1.4.0"))
        #expect(await events.waitForState(.connected(macName: "Mac")))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct BridgeClientTests {
    @Test func sendsHelloFirst() async throws {
        let rig = Rig()
        await rig.client.start()
        let first = try #require(await rig.mac.nextFrame())
        #expect(first == .hello(protocolVersion: 1, deviceId: "d1", token: "t1", app: "critter-ios/test"))
        #expect(rig.mac.connects == [FakeMac.Connect(host: home.host, port: home.port, fingerprint: pin)])
        await rig.client.stop()
    }

    @Test func welcomeMeansConnected() async throws {
        let rig = Rig()
        try await rig.connect()
        #expect(rig.events.states.last == .connected(macName: "Mac"))
        #expect(rig.events.all.contains(.connectedTo(home)))
        await rig.client.stop()
    }

    @Test func snapshotsArePassedOn() async throws {
        let rig = Rig()
        try await rig.connect()
        rig.mac.send(.snapshot(seq: 3, sentAt: 1_760_000_000_000, body: emptySnapshot))
        #expect(await rig.events.waitFor { $0.contains(.snapshot(seq: 3, sentAt: 1_760_000_000_000, body: emptySnapshot)) })
        await rig.client.stop()
    }

    @Test func requestBeforeWelcomeFailsWithoutSending() async throws {
        let rig = Rig()
        await rig.client.start()
        _ = try #require(await rig.mac.nextFrame())
        let result = await rig.client.request(.seen(sessionId: "s1"))
        #expect(result == .failed("未连接"))
        await settle()
        #expect(rig.mac.received == [.hello(protocolVersion: 1, deviceId: "d1", token: "t1", app: "critter-ios/test")])
        await rig.client.stop()
    }

    @Test func requestsAreMatchedById() async throws {
        let rig = Rig()
        try await rig.connect()
        async let first = rig.client.request(.seen(sessionId: "s1"))
        async let second = rig.client.request(.say(sessionId: "s1", text: "continue"))
        let frames = [try #require(await rig.mac.nextFrame()), try #require(await rig.mac.nextFrame())]
        func id(of kind: (ClientMessage) -> Bool) throws -> String {
            try #require(frames.first(where: kind)?.commandId)
        }
        let seenId = try id { if case .seen = $0 { true } else { false } }
        let sayId = try id { if case .say = $0 { true } else { false } }
        #expect(seenId != sayId)
        #expect(seenId.hasPrefix("a") && Int(seenId.dropFirst()) != nil)
        // Replies in the opposite order.
        rig.mac.send(.result(id: sayId, ok: false, reason: .unavailable, message: "say failed"))
        rig.mac.send(.result(id: seenId, ok: true, reason: nil, message: nil))
        #expect(await first == CommandResult(ok: true, reason: nil, message: nil))
        #expect(await second == CommandResult(ok: false, reason: .unavailable, message: "say failed"))
        await rig.client.stop()
    }

    @Test func requestTimesOutAndDropsTheConnection() async throws {
        let rig = Rig(requestTimeout: .milliseconds(50))
        try await rig.connect()
        async let result = rig.client.request(.seen(sessionId: "s1"))
        _ = try #require(await rig.mac.nextFrame())
        #expect(await result == .failed("超时"))
        #expect(await rig.mac.waitForConnects(2))
        await rig.client.stop()
    }

    @Test func inFlightRequestFailsWhenTheLinkDrops() async throws {
        let rig = Rig()
        try await rig.connect()
        async let result = rig.client.request(.answer(requestId: "r1", payload: AnswerPayload(decision: "allow")))
        _ = try #require(await rig.mac.nextFrame())
        rig.mac.drop()
        #expect(await result == .failed("未连接"))
        await rig.client.stop()
    }

    @Test func badTokenNeedsRepairAndStops() async throws {
        let rig = Rig()
        await rig.client.start()
        _ = try #require(await rig.mac.nextFrame())
        rig.mac.send(.denied(reason: .badToken))
        #expect(await rig.events.waitForState(.needsRepair(reason: "这台手机已不在电脑的配对列表里，请重新配对")))
        await settle()
        #expect(rig.mac.connects.count == 1)
        #expect(rig.mac.openSockets == 0)
        await rig.client.stop()
    }

    @Test func pinMismatchNeedsRepairAndStops() async throws {
        let rig = Rig()
        rig.mac.failNextConnects(.pinMismatch)
        await rig.client.start()
        #expect(await rig.events.waitForState(.needsRepair(reason: "证书指纹与配对时不一致，请重新配对")))
        await settle()
        #expect(rig.mac.connects.count == 1)
        #expect(rig.sleeper.delays.isEmpty)
        await rig.client.stop()
    }

    @Test func noCredentialsNeedsRepair() async throws {
        let rig = Rig(credentials: nil)
        await rig.client.start()
        #expect(await rig.events.waitForState(.needsRepair(reason: "尚未配对")))
        await settle()
        #expect(rig.mac.connects.isEmpty)
        await rig.client.stop()
    }

    @Test func retriesWithBackoffAndResetsAfterSuccess() async throws {
        let rig = Rig()
        rig.mac.failNextConnects(.unreachable, times: 4)
        await rig.client.start()
        #expect(await rig.mac.waitForConnects(5))
        try await rig.welcomeNextHello()
        #expect(rig.sleeper.delays == [2, 4, 8, 16].map { Duration.seconds($0) })
        rig.mac.drop()
        #expect(await rig.sleeper.waitForDelays(5))
        #expect(rig.sleeper.delays == [2, 4, 8, 16, 2].map { Duration.seconds($0) })
        await rig.client.stop()
    }

    @Test func offlineKeepsTheTimeTheStreakBegan() async throws {
        // A real pause between attempts, so a `since` taken anew would differ.
        let rig = Rig(sleeper: Sleeper(.after(.milliseconds(10))))
        rig.mac.failNextConnects(.unreachable, times: 2)
        await rig.client.start()
        #expect(await rig.mac.waitForConnects(3))
        let since = rig.events.offlineSince
        #expect(since.count == 2)
        #expect(Set(since).count == 1)
        // Connected, then dropped: a new streak.
        try await rig.welcomeNextHello()
        rig.mac.drop()
        #expect(await eventually { rig.events.offlineSince.count == 3 })
        let streaks = rig.events.offlineSince
        #expect(streaks[2] > streaks[0])
        await rig.client.stop()
    }

    @Test func reconnectNowCutsTheWaitShort() async throws {
        let rig = Rig(sleeper: Sleeper(.hold))
        rig.mac.failNextConnects(.unreachable)
        await rig.client.start()
        #expect(await rig.sleeper.waitForDelays(1))
        #expect(rig.mac.connects.count == 1)
        await rig.client.reconnectNow()
        #expect(await rig.mac.waitForConnects(2))
        await rig.client.stop()
    }

    @Test func reconnectNowWhileConnectedMakesANewConnection() async throws {
        let rig = Rig(sleeper: Sleeper(.hold))
        try await rig.connect()
        await rig.client.reconnectNow()
        #expect(await rig.mac.waitForConnects(2))
        try await rig.welcomeNextHello()
        #expect(rig.mac.openSockets == 1)
        await rig.client.stop()
    }

    @Test func stopEndsTheLoopAndStartBeginsAfresh() async throws {
        let rig = Rig(sleeper: Sleeper(.hold))
        rig.mac.failNextConnects(.unreachable, times: 3)
        await rig.client.start()
        #expect(await rig.sleeper.waitForDelays(1))
        await rig.client.reconnectNow()
        #expect(await rig.sleeper.waitForDelays(2))
        await rig.client.stop()
        #expect(rig.events.states.last == .idle)
        await settle()
        #expect(rig.mac.connects.count == 2)
        #expect(rig.events.states.last == .idle)
        await rig.client.start()
        #expect(await rig.sleeper.waitForDelays(3))
        #expect(rig.sleeper.delays == [2, 4, 2].map { Duration.seconds($0) })
        await rig.client.stop()
    }

    @Test func neverMoreThanOneSocket() async throws {
        let rig = Rig()
        rig.mac.autoWelcome = "Mac"
        // A stop while a slow connect is under way, then a start whose connect is quick: the slow
        // one's socket opens later and must be closed before the next one opens.
        rig.mac.connectDelay = .milliseconds(50)
        await rig.client.start()
        #expect(await rig.mac.waitForConnects(1))
        rig.mac.connectDelay = nil
        await rig.client.stop()
        await rig.client.start()
        #expect(await rig.events.waitForState(.connected(macName: "Mac")))
        #expect(await eventually { rig.mac.finishedConnects == 2 })
        #expect(rig.mac.maxOpenSockets == 1)
        // Then whatever order the calls come in.
        for _ in 0..<5 {
            await rig.client.start()
            await rig.client.reconnectNow()
            await rig.client.stop()
            await rig.client.start()
            await rig.client.reconnectNow()
            await rig.client.start()
            #expect(await rig.events.waitForState(.connected(macName: "Mac")))
            await rig.client.reconnectNow()
        }
        #expect(await rig.events.waitForState(.connected(macName: "Mac")))
        await rig.client.stop()
        await settle()
        // At least the two first ones and one after each stop + start.
        #expect(rig.mac.connects.count >= 7)
        #expect(rig.mac.maxOpenSockets == 1)
        #expect(rig.mac.openSockets == 0)
    }

    @Test func failedPingDropsTheConnection() async throws {
        let rig = Rig(pingInterval: .milliseconds(20))
        rig.mac.pingError = .closed(cleanly: false)
        try await rig.connect()
        #expect(await rig.mac.waitForConnects(2))
        await rig.client.stop()
    }

    @Test func unansweredPingDropsTheConnection() async throws {
        let rig = Rig(requestTimeout: .milliseconds(50), pingInterval: .milliseconds(20))
        rig.mac.pingHangs = true
        try await rig.connect()
        #expect(await rig.mac.waitForConnects(2))
        await rig.client.stop()
    }

    @Test func skinRequestReturnsTheManifestOrNil() async throws {
        let rig = Rig()
        try await rig.connect()
        let manifest = JSONValue.object(["name": .string("sprig")])

        async let found = rig.client.requestSkin("sprig")
        let ask = try #require(await rig.mac.nextFrame())
        guard case .skin(let id, "sprig") = ask else {
            Issue.record("expected a skin request, got \(ask)")
            return
        }
        rig.mac.send(.skin(id: id, name: "sprig", manifest: manifest))
        #expect(await found == manifest)

        async let missing = rig.client.requestSkin("nope")
        let askAgain = try #require(await rig.mac.nextFrame())
        rig.mac.send(.skin(id: askAgain.commandId, name: "nope", manifest: nil))
        #expect(await missing == nil)
        await rig.client.stop()
    }

    @Test func unknownFramesAreIgnored() async throws {
        let rig = Rig()
        try await rig.connect()
        rig.mac.sendRaw(#"{"type":"future"}"#)
        rig.mac.send(.snapshot(seq: 1, sentAt: 1, body: emptySnapshot))
        #expect(await rig.events.waitFor { $0.contains(.snapshot(seq: 1, sentAt: 1, body: emptySnapshot)) })
        #expect(rig.mac.connects.count == 1)
        await rig.client.stop()
    }

    @Test func aFailedAddressIsResolvedAgainAfterTheFailure() async throws {
        let rig = Rig()
        rig.mac.failNextConnects(.unreachable)
        await rig.client.start()
        try await rig.welcomeNextHello()
        rig.mac.drop()
        #expect(await rig.mac.waitForConnects(3))
        // Failed to connect -> true; connected (and dropped later) -> false.
        #expect(rig.resolver.afterFailure == [false, true, false])
        await rig.client.stop()
    }
}
