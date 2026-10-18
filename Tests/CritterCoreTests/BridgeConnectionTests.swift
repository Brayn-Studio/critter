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
    var submitResult = true
    var sayResult = SayOutcome.sent
    var submitted: [(AnswerPayload, String)] = []
    var seen: [String] = []
    var said: [(String, String)] = []

    func verify(deviceId: String, token: String) -> DeviceRecord? {
        token == goodToken ? DeviceRecord(id: deviceId, name: "P", tokenHash: "h", pairedAt: 0) : nil
    }
    func consumePairingCode(_ code: String) -> Bool { code == goodCode }
    func pendingRequest(_ requestId: String) -> PendingRequest? { requests[requestId] }
    func originalToolInput(_ requestId: String) -> [String: Any]? { toolInputs[requestId] }
    func submitAnswer(_ payload: AnswerPayload, requestId: String) -> Bool { submitted.append((payload, requestId)); return submitResult }
    func markSeen(sessionId: String) { seen.append(sessionId) }
    func say(text: String, sessionId: String) -> SayOutcome { said.append((text, sessionId)); return sayResult }
    func skinManifest(name: String) -> JSONValue? { name == "clawd" ? .object(["name": .string(name)]) : nil }
    func snapshotMessage() -> ServerMessage {
        .snapshot(seq: 1, sentAt: 2, body: SnapshotBody(
            sessions: [], pending: [],
            prefs: BridgePrefs(skin: "clawd", randomSkins: false, idleDim: 0.5, mergeThreshold: 5, soundTheme: "pixel")))
    }
}

private func request(_ id: String, kind: PendingKind) -> PendingRequest {
    PendingRequest(requestId: id, sessionId: "s", kind: kind, toolName: "T", summary: "", input: .null,
                   matchKey: "k", createdAt: 0, expiresAt: 1, hookPid: 1)
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
    s.submitResult = false
    guard case .send(.result(_, let ok, let reason, _))? = c.receive(frame).first else { Issue.record("no result"); return }
    #expect(!ok && reason == .failed)
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

@Test func seenMarksSession() {
    let s = FakeServices()
    let c = readyConnection(s)
    #expect(c.receive(ClientMessage.seen(id: "9", sessionId: "s1").encode()) == [.send(.result(id: "9", ok: true, reason: nil, message: nil))])
    #expect(s.seen == ["s1"])
}

@Test func skinRequestRepliesWithManifest() {
    let c = readyConnection(FakeServices())
    #expect(c.receive(ClientMessage.skin(id: "1", name: "clawd").encode())
        == [.send(.skin(id: "1", name: "clawd", manifest: .object(["name": .string("clawd")])))])
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
