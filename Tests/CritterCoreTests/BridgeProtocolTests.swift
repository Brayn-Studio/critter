import Foundation
import Testing
@testable import CritterCore

func sampleBody() -> SnapshotBody {
    SnapshotBody(
        sessions: [BridgeSession(
            id: "s1", name: "critter", source: .terminal, state: .waiting, detail: "Bash: swift test",
            activity: "bash", cwd: "~/CODESPACE/clawd", branch: "main", model: "Opus 5.5",
            context: BridgeContext(usedPercent: 42.5, windowSize: 1_000_000, estimated: false),
            skin: "clawd", eventTime: 1_760_000_000_000, startedAt: 1_759_990_000_000, tracked: true
        )],
        limits: BridgeLimits(
            fiveHour: RateWindow(usedPercentage: 12.5, resetsAt: 1_760_003_600_000),
            sevenDay: RateWindow(usedPercentage: 30, resetsAt: 1_760_500_000_000), updatedAt: 1_760_000_000_000),
        pending: [BridgePending(
            requestId: "r1", sessionId: "s1", kind: .permission, toolName: "Bash", summary: "swift test",
            input: .object(["command": .string("swift test")]), createdAt: 1_760_000_000_000, expiresAt: 1_760_000_600_000)],
        prefs: BridgePrefs(skin: "clawd", randomSkins: false, idleDim: 0.6, mergeThreshold: 5, soundTheme: "pixel")
    )
}

@Test func clientMessagesRoundTrip() {
    let messages: [ClientMessage] = [
        .hello(protocolVersion: 1, deviceId: "d", token: "t", app: "android/1.0"),
        .pair(code: "ABCD2345", deviceName: "Pixel"),
        .answer(id: "1", requestId: "r", payload: AnswerPayload(decision: "deny", message: "no", answers: ["q": "a"])),
        .answer(id: nil, requestId: "r", payload: AnswerPayload(decision: "allow")),
        .seen(id: "2", sessionId: "s"),
        .say(id: nil, sessionId: "s", text: "hi"),
        .skin(id: "3", name: "clawd"),
    ]
    for m in messages { #expect(ClientMessage.decode(m.encode()) == m) }
}

@Test func serverMessagesRoundTrip() {
    let messages: [ServerMessage] = [
        .welcome(macName: "Mac", version: "1.0"),
        .paired(deviceId: "d", token: "t", macName: "Mac"),
        .denied(reason: .protocolMismatch),
        .snapshot(seq: 3, sentAt: 5, body: sampleBody()),
        .skin(id: "1", name: "clawd", manifest: .object(["a": .number(1)])),
        .result(id: nil, ok: false, reason: .resolved, message: "x"),
        .result(id: "1", ok: true, reason: nil, message: nil),
    ]
    for m in messages { #expect(ServerMessage.decode(m.encode()) == m) }
}

@Test func decodeRejectsUnknownOrMalformed() {
    #expect(ClientMessage.decode(Data(#"{"type":"nope"}"#.utf8)) == nil)
    #expect(ClientMessage.decode(Data(#"{"type":"hello","deviceId":"d"}"#.utf8)) == nil)
    #expect(ClientMessage.decode(Data(#"{"type":"say","sessionId":"s"}"#.utf8)) == nil)
    #expect(ClientMessage.decode(Data("not json".utf8)) == nil)
    #expect(ServerMessage.decode(Data(#"{"type":"denied","reason":"zzz"}"#.utf8)) == nil)
}

@Test func deniedProtocolUsesWireValueProtocol() throws {
    let obj = try #require(JSONSerialization.jsonObject(with: ServerMessage.denied(reason: .protocolMismatch).encode()) as? [String: Any])
    #expect(obj["reason"] as? String == "protocol")
}

@Test func serverSnapshotEncodesDocumentedShape() throws {
    let data = ServerMessage.snapshot(seq: 7, sentAt: 1_760_000_000_000, body: sampleBody()).encode()
    let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(obj["type"] as? String == "snapshot")
    #expect(obj["seq"] as? Int == 7)
    #expect(obj["sentAt"] as? Int64 == 1_760_000_000_000)
    let sessions = try #require(obj["sessions"] as? [[String: Any]])
    let context = try #require(sessions[0]["context"] as? [String: Any])
    #expect(context["usedPercent"] as? Double == 42.5)
    let limits = try #require(obj["limits"] as? [String: Any])
    let five = try #require(limits["fiveHour"] as? [String: Any])
    #expect(five["resetsAt"] as? Int64 == 1_760_003_600_000)
    let pending = try #require(obj["pending"] as? [[String: Any]])
    let input = try #require(pending[0]["input"] as? [String: Any])
    #expect(input["command"] as? String == "swift test")
    let prefs = try #require(obj["prefs"] as? [String: Any])
    #expect(prefs["mergeThreshold"] as? Int == 5)
}
