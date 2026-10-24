import Foundation
import Testing
@testable import CritterCore

private final class FakeServices: BridgeServices {
    var macName = "Mac"
    var version = "1.0"
    var goodToken = "tok"
    var goodCode = "CODE2345"
    var requests: [String: PendingRequest] = [:]
    var toolInputs: [String: [String: Any]] = [:]
    var submitResult = AnswerOutcome.accepted
    var sayResult = SayOutcome.sent
    var submitted: [(AnswerPayload, String)] = []
    var seen: [String] = []
    var said: [(String, String)] = []
    var interrupted: [String] = []
    var registered: [(String, PushRegistration)] = []
    var registerResult = true

    func verify(deviceId: String, token: String) -> DeviceRecord? {
        token == goodToken ? DeviceRecord(id: deviceId, name: "P", tokenHash: "h", pairedAt: 0) : nil
    }
    func consumePairingCode(_ code: String) -> Bool { code == goodCode }
    func pendingRequest(_ requestId: String) -> PendingRequest? { requests[requestId] }
    func originalToolInput(_ requestId: String) -> [String: Any]? { toolInputs[requestId] }
    func submitAnswer(_ payload: AnswerPayload, requestId: String) -> AnswerOutcome { submitted.append((payload, requestId)); return submitResult }
    func markSeen(sessionId: String) { seen.append(sessionId) }
    func say(text: String, sessionId: String) -> SayOutcome { said.append((text, sessionId)); return sayResult }
    func interrupt(sessionId: String) -> SayOutcome { interrupted.append(sessionId); return .sent }
    func registerPush(deviceId: String, _ registration: PushRegistration) -> Bool {
        registered.append((deviceId, registration))
        return registerResult
    }
    func skinManifest(name: String) -> JSONValue? { name == "sprig" ? .object(["name": .string(name)]) : nil }
    func snapshotMessage() -> ServerMessage {
        .snapshot(seq: 1, sentAt: 2, body: SnapshotBody(
            sessions: [], pending: [],
            prefs: BridgePrefs(skin: "sprig", randomSkins: false, idleDim: 0.5, mergeThreshold: 5, soundTheme: "pixel")))
    }
}

private func request(_ id: String, kind: PendingKind, expiresAt: Int64 = .max) -> PendingRequest {
    PendingRequest(requestId: id, sessionId: "s", kind: kind, toolName: "T", summary: "", input: .null,
                   matchKey: "k", createdAt: 0, expiresAt: expiresAt, hookPid: 1)
}

private func hello(version: Int = 1, token: String = "tok") -> Data {
    ClientMessage.hello(protocolVersion: version, deviceId: "dev", token: token, app: "t").encode()
}

private func readyConnection(_ s: FakeServices) -> BridgeConnection {
    let c = BridgeConnection(services: s)
    _ = c.receive(hello())
    return c
}

private func denied(_ r: DenyReason) -> [BridgeConnection.Output] { [.send(.denied(reason: r)), .close] }

@Test func helloWithGoodTokenGetsWelcomeAndSnapshot() {
    let s = FakeServices()
    let c = BridgeConnection(services: s)
    #expect(c.receive(hello()) == [.send(.welcome(macName: "Mac", version: "1.0")), .send(s.snapshotMessage())])
    #expect(c.phase == .ready(deviceId: "dev"))
}

@Test func helloWithBadTokenIsDeniedAndClosed() {
    let c = BridgeConnection(services: FakeServices())
    #expect(c.receive(hello(token: "bad")) == denied(.badToken))
    #expect(c.phase == .closed)
}

@Test func wrongProtocolVersionIsDenied() {
    let c = BridgeConnection(services: FakeServices())
    #expect(c.receive(hello(version: 2)) == denied(.protocolMismatch))
}

@Test func firstFrameMustBeHelloOrPair() {
    let c1 = BridgeConnection(services: FakeServices())
    #expect(c1.receive(Data("junk".utf8)) == denied(.protocolMismatch))
    let c2 = BridgeConnection(services: FakeServices())
    #expect(c2.receive(ClientMessage.seen(id: nil, sessionId: "s").encode()) == denied(.protocolMismatch))
    #expect(c2.phase == .closed)
}

@Test func pairWaitsForApprovalThenPairs() {
    let s = FakeServices()
    let c = BridgeConnection(services: s)
    #expect(c.receive(ClientMessage.pair(code: "CODE2345", deviceName: "Pixel").encode()).isEmpty)
    #expect(c.phase == .awaitingApproval(deviceName: "Pixel"))
    #expect(c.receive(hello()).isEmpty)   // ignored while awaiting
    #expect(c.approvePairing(deviceId: "d1", token: "t1") == [
        .send(.paired(deviceId: "d1", token: "t1", macName: "Mac")),
        .send(.welcome(macName: "Mac", version: "1.0")),
        .send(s.snapshotMessage()),
    ])
    #expect(c.phase == .ready(deviceId: "d1"))
}

@Test func rejectedPairingCloses() {
    let c = BridgeConnection(services: FakeServices())
    _ = c.receive(ClientMessage.pair(code: "CODE2345", deviceName: "Pixel").encode())
    #expect(c.rejectPairing() == denied(.rejected))
    #expect(c.phase == .closed)
}

@Test func badPairingCodeIsDenied() {
    let c = BridgeConnection(services: FakeServices())
    #expect(c.receive(ClientMessage.pair(code: "NOPE", deviceName: "P").encode()) == denied(.badCode))
}

@Test func answerForResolvedRequestRepliesResolved() {
    let s = FakeServices()
    let c = readyConnection(s)
    let out = c.receive(ClientMessage.answer(id: "1", requestId: "gone", payload: AnswerPayload(decision: "allow")).encode())
    #expect(out == [.send(.result(id: "1", ok: false, reason: .resolved, message: "已在电脑上处理"))])
    #expect(s.submitted.isEmpty)
}

@Test func answerWithForeignQuestionIsInvalid() {
    let s = FakeServices()
    s.requests["r"] = request("r", kind: .question)
    s.toolInputs["r"] = ["questions": [["question": "Which?"]]]
    let c = readyConnection(s)
    let out = c.receive(ClientMessage.answer(id: "1", requestId: "r", payload: AnswerPayload(answers: ["Other?": "x"])).encode())
    guard case .send(.result(_, let ok, let reason, _))? = out.first else { Issue.record("no result"); return }
    #expect(!ok && reason == .invalid)
    #expect(s.submitted.isEmpty)
}

@Test func validAnswerIsSubmitted() {
    let s = FakeServices()
    s.requests["r"] = request("r", kind: .permission)
    let c = readyConnection(s)
    let frame = ClientMessage.answer(id: "1", requestId: "r", payload: AnswerPayload(decision: "allow")).encode()
    #expect(c.receive(frame) == [.send(.result(id: "1", ok: true, reason: nil, message: nil))])
    #expect(s.submitted.count == 1 && s.submitted[0].1 == "r")
    s.submitResult = .failed
    guard case .send(.result(_, let ok, let reason, _))? = c.receive(frame).first else { Issue.record("no result"); return }
    #expect(!ok && reason == .failed)
}

/// Two phones answering the same request: only the first is told it got in.
@Test func answerAfterAnotherAnswerRepliesResolved() {
    let s = FakeServices()
    s.requests["r"] = request("r", kind: .permission)
    s.submitResult = .alreadyAnswered
    let c = readyConnection(s)
    let frame = ClientMessage.answer(id: "2", requestId: "r", payload: AnswerPayload(decision: "deny")).encode()
    guard case .send(.result(let id, let ok, let reason, _))? = c.receive(frame).first else { Issue.record("no result"); return }
    #expect(id == "2" && !ok && reason == .resolved)
}

/// A question request must be answered in full: answering one of two questions is invalid.
@Test func partialQuestionAnswerIsInvalid() {
    let s = FakeServices()
    s.requests["r"] = request("r", kind: .question)
    s.toolInputs["r"] = ["questions": [["question": "Which?"], ["question": "When?"]]]
    let c = readyConnection(s)
    let out = c.receive(ClientMessage.answer(id: "1", requestId: "r", payload: AnswerPayload(answers: ["Which?": "x"])).encode())
    guard case .send(.result(_, let ok, let reason, _))? = out.first else { Issue.record("no result"); return }
    #expect(!ok && reason == .invalid)
    #expect(s.submitted.isEmpty)
}

@Test func sayValidatesLengthAndMapsOutcome() {
    let s = FakeServices()
    let c = readyConnection(s)
    func reason(_ text: String) -> ResultReason? {
        guard case .send(.result(_, _, let r, _))? = c.receive(ClientMessage.say(id: nil, sessionId: "s", text: text).encode()).first else { return .expired }
        return r
    }
    #expect(reason("   \n") == .invalid)
    #expect(reason(String(repeating: "a", count: 4001)) == .invalid)
    #expect(s.said.isEmpty)
    #expect(reason("hi") == nil)
    #expect(reason(String(repeating: "a", count: 4000)) == nil)
    s.sayResult = .unavailable
    #expect(reason("hi") == .unavailable)
    s.sayResult = .failed
    #expect(reason("hi") == .failed)
}

/// The length is counted in UTF-16 code units, as the phone counts it (Kotlin's `String.length`):
/// whatever a phone lets through, the Mac takes.
@Test func sayCountsUTF16Units() {
    let s = FakeServices()
    let c = readyConnection(s)
    func reason(_ text: String) -> ResultReason? {
        guard case .send(.result(_, _, let r, _))? = c.receive(ClientMessage.say(id: "1", sessionId: "s", text: text).encode()).first else { return .expired }
        return r
    }
    let emoji = "😀" // one character, two UTF-16 code units
    #expect(reason(String(repeating: emoji, count: 2000)) == nil)
    #expect(reason("  " + String(repeating: emoji, count: 2000) + "\n") == nil)
    #expect(reason(String(repeating: emoji, count: 2000) + "a") == .invalid)
    #expect(s.said.count == 2)
    // A frame exactly as phones have always sent it (the protocol doc's example).
    let docFrame = Data(#"{"id":"c6","sessionId":"s1","text":"continue","type":"say"}"#.utf8)
    #expect(c.receive(docFrame) == [.send(.result(id: "c6", ok: true, reason: nil, message: nil))])
    #expect(s.said.last.map { [$0.0, $0.1] } == ["continue", "s1"])
}

/// Once its `expiresAt` has come the hook no longer waits for an answer: one that arrives then
/// is turned away as `expired`, and nothing is written.
@Test func answerToAnExpiredRequestSaysExpired() {
    let s = FakeServices()
    let now: Int64 = 1_000_000
    let c = BridgeConnection(services: s, now: { now })
    _ = c.receive(hello())
    s.requests["late"] = request("late", kind: .permission, expiresAt: now - 1)
    s.requests["due"] = request("due", kind: .permission, expiresAt: now)
    s.requests["fine"] = request("fine", kind: .permission, expiresAt: now + 1)
    for id in ["late", "due"] {
        let out = c.receive(ClientMessage.answer(id: "a", requestId: id, payload: AnswerPayload(decision: "allow")).encode())
        #expect(out == [.send(.result(id: "a", ok: false, reason: .expired, message: "这个请求已经过期了"))])
    }
    // A frame exactly as phones have always sent it (the protocol doc's example).
    let docFrame = Data(#"{"id":"c1","payload":{"decision":"allow"},"requestId":"late","type":"answer"}"#.utf8)
    #expect(c.receive(docFrame) == [.send(.result(id: "c1", ok: false, reason: .expired, message: "这个请求已经过期了"))])
    #expect(s.submitted.isEmpty)
    let out = c.receive(ClientMessage.answer(id: "b", requestId: "fine", payload: AnswerPayload(decision: "allow")).encode())
    #expect(out == [.send(.result(id: "b", ok: true, reason: nil, message: nil))])
    #expect(s.submitted.map(\.1) == ["fine"])
}

@Test func seenMarksSession() {
    let s = FakeServices()
    let c = readyConnection(s)
    #expect(c.receive(ClientMessage.seen(id: "9", sessionId: "s1").encode()) == [.send(.result(id: "9", ok: true, reason: nil, message: nil))])
    #expect(s.seen == ["s1"])
}

@Test func skinRequestRepliesWithManifest() {
    let c = readyConnection(FakeServices())
    #expect(c.receive(ClientMessage.skin(id: "1", name: "sprig").encode())
        == [.send(.skin(id: "1", name: "sprig", manifest: .object(["name": .string("sprig")])))])
}

@Test func broadcastOnlyWhenReady() {
    let s = FakeServices()
    let c = BridgeConnection(services: s)
    #expect(c.broadcast(s.snapshotMessage()).isEmpty)
    _ = c.receive(hello())
    #expect(c.broadcast(s.snapshotMessage()) == [.send(s.snapshotMessage())])
}

@Test func oversizedFrameCloses() {
    let c = BridgeConnection(services: FakeServices())
    #expect(c.receive(Data(count: BridgeProtocol.maxFrameBytes + 1)) == [.close])
    #expect(c.phase == .closed)
}

@Test func garbageWhileReadyIsIgnored() {
    let c = readyConnection(FakeServices())
    #expect(c.receive(Data("garbage".utf8)).isEmpty)
    #expect(c.phase == .ready(deviceId: "dev"))
}

@Test func codexInterruptCommandRequiresPairingAndRoutesToSession() {
    let services = FakeServices()
    let before = BridgeConnection(services: services)
    let frame = ClientMessage.interrupt(id: "stop-1", sessionId: "codex-thread").encode()
    #expect(before.receive(frame) == [.send(.denied(reason: .protocolMismatch)), .close])
    let ready = readyConnection(services)
    #expect(ready.receive(frame) == [.send(.result(id: "stop-1", ok: true, reason: nil, message: nil))])
    #expect(services.interrupted == ["codex-thread"])
}

private func registration(
    token: String = "aa11", key: String = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8", activity: ActivityRegistration? = nil
) -> PushRegistration {
    PushRegistration(
        token: token, environment: .sandbox, bundleId: "com.braynlabs.critter", key: key, notifyDone: true, notifyError: false,
        activity: activity
    )
}

@Test func aTokenThatIsNotLowercaseHexIsRefused() {
    let s = FakeServices()
    let c = readyConnection(s)
    let refused = [
        registration(token: "AA11"), registration(token: "zz11"), registration(token: "aa 11"), registration(token: "aa\u{FF11}"),
        registration(activity: ActivityRegistration(enabled: true, startToken: "5A5A")),
        registration(activity: ActivityRegistration(enabled: true, startToken: "5a5a", activityId: "A1", activityToken: "9f9g")),
    ]
    for (n, bad) in refused.enumerated() {
        #expect(c.receive(ClientMessage.push(id: "p\(n)", registration: bad).encode())
            == [.send(.result(id: "p\(n)", ok: false, reason: .invalid, message: "推送登记无效"))])
    }
    #expect(s.registered.isEmpty)
    // Lowercase hex everywhere, an empty start token, or an unregistration (whatever it holds) are fine.
    let fine = [
        registration(activity: ActivityRegistration(enabled: true, startToken: "5a5a", activityId: "A1", activityToken: "0f9e")),
        registration(activity: ActivityRegistration(enabled: true, startToken: "")),
        registration(token: "", activity: ActivityRegistration(enabled: true, startToken: "NOT HEX")),
    ]
    for item in fine {
        #expect(c.receive(ClientMessage.push(id: "ok", registration: item).encode()) == [.send(.result(id: "ok", ok: true, reason: nil, message: nil))])
    }
    #expect(s.registered.count == 3)
}

@Test func connectionAnswersPushWithResult() {
    let s = FakeServices()
    let c = readyConnection(s)
    // Stored.
    #expect(c.receive(ClientMessage.push(id: "p1", registration: registration()).encode())
        == [.send(.result(id: "p1", ok: true, reason: nil, message: nil))])
    #expect(s.registered.map(\.0) == ["dev"])
    #expect(s.registered.first?.1 == registration())
    // A key that is not 32 bytes: nothing is stored.
    #expect(c.receive(ClientMessage.push(id: "p2", registration: registration(key: "short")).encode())
        == [.send(.result(id: "p2", ok: false, reason: .invalid, message: "推送登记无效"))])
    #expect(s.registered.count == 1)
    // An empty token takes the registration back, whatever the key.
    #expect(c.receive(ClientMessage.push(id: "p3", registration: registration(token: "", key: "")).encode())
        == [.send(.result(id: "p3", ok: true, reason: nil, message: nil))])
    #expect(s.registered.count == 2)
    // The Mac could not keep it.
    s.registerResult = false
    #expect(c.receive(ClientMessage.push(id: nil, registration: registration()).encode())
        == [.send(.result(id: nil, ok: false, reason: .failed, message: "保存失败"))])
    #expect(c.phase == .ready(deviceId: "dev"))
}

@Test func pushBeforeHelloIsAProtocolError() {
    let s = FakeServices()
    let frame = ClientMessage.push(id: "p1", registration: registration()).encode()
    let c = BridgeConnection(services: s)
    #expect(c.receive(frame) == denied(.protocolMismatch))
    #expect(c.phase == .closed)
    #expect(s.registered.isEmpty)
    // Nor does a phone still waiting for approval get to register.
    let waiting = BridgeConnection(services: s)
    _ = waiting.receive(ClientMessage.pair(code: "CODE2345", deviceName: "Pixel").encode())
    #expect(waiting.receive(frame).isEmpty)
    #expect(s.registered.isEmpty)
}

@Test func aPairedPhoneMayRegisterRightAfterPairing() {
    let s = FakeServices()
    let c = BridgeConnection(services: s)
    _ = c.receive(ClientMessage.pair(code: "CODE2345", deviceName: "Pixel").encode())
    _ = c.approvePairing(deviceId: "d1", token: "t1")
    #expect(c.receive(ClientMessage.push(id: "p1", registration: registration()).encode())
        == [.send(.result(id: "p1", ok: true, reason: nil, message: nil))])
    #expect(s.registered.first?.0 == "d1")
}
