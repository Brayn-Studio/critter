import Foundation
import Testing
@testable import CritterKit

/// `docs/critter-bridge-protocol.md`, found from this file: Tests/CritterKitTests/ -> repo root.
private let protocolDoc = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("docs/critter-bridge-protocol.md")

/// The JSON example under the doc's `### snapshot` heading, as written there.
private func docSnapshotText() throws -> String {
    let doc = try String(contentsOf: protocolDoc, encoding: .utf8)
    let heading = try #require(doc.range(of: "### snapshot\n"))
    let afterHeading = doc[heading.upperBound...]
    let open = try #require(afterHeading.range(of: "```json\n"))
    let body = afterHeading[open.upperBound...]
    let close = try #require(body.range(of: "\n```"))
    return String(body[..<close.lowerBound])
}

/// The doc's snapshot as a frame, after `edit` has changed it.
private func docSnapshotFrame(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
    var object = try #require(
        try JSONSerialization.jsonObject(with: Data(docSnapshotText().utf8)) as? [String: Any]
    )
    edit(&object)
    return try JSONSerialization.data(withJSONObject: object)
}

private func snapshotBody(_ frame: Data) throws -> SnapshotBody {
    let message = try #require(ServerMessage.decode(frame))
    guard case .snapshot(_, _, let body) = message else {
        Issue.record("not a snapshot: \(message)")
        throw CocoaError(.coderReadCorrupt)
    }
    return body
}

private func editFirstSession(_ object: inout [String: Any], _ key: String, _ value: String) {
    var sessions = object["sessions"] as? [[String: Any]] ?? []
    sessions[0][key] = value
    object["sessions"] = sessions
}

@Test func unknownSourceDecodesAsOther() throws {
    let frame = try docSnapshotFrame { editFirstSession(&$0, "source", "jetbrains") }
    let body = try snapshotBody(frame)
    #expect(body.sessions.count == 1)
    #expect(body.sessions[0].source == .other)
    #expect(body.sessions[0].state == .waiting)
}

@Test func unknownStateDecodesAsIdle() throws {
    let frame = try docSnapshotFrame { editFirstSession(&$0, "state", "thinking") }
    let body = try snapshotBody(frame)
    #expect(body.sessions.count == 1)
    #expect(body.sessions[0].state == .idle)
    #expect(body.sessions[0].source == .terminal)
}

@Test func pendingOfUnknownKindIsDropped() throws {
    let frame = try docSnapshotFrame { object in
        var pending = object["pending"] as? [[String: Any]] ?? []
        var unknown = pending[0]
        unknown["requestId"] = "r2"
        unknown["kind"] = "elicitation"
        pending.append(unknown)
        object["pending"] = pending
    }
    let body = try snapshotBody(frame)
    #expect(body.pending.map(\.requestId) == ["r1"])
    #expect(body.sessions.count == 1)
}

@Test func protocolDocSnapshotStillDecodes() throws {
    let body = try snapshotBody(Data(try docSnapshotText().utf8))
    #expect(body.sessions[0].source == .terminal)
    #expect(body.sessions[0].state == .waiting)
    #expect(body.pending[0].kind == .permission)
}

@Test func sessionEncodingIsUnchanged() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let full = BridgeSession(
        id: "s1", name: "critter", source: .codexDesktop, state: .waiting,
        detail: "Bash: swift test", activity: "bash", cwd: "~/CODESPACE/clawd", branch: "main",
        model: "Opus 5.5", context: BridgeContext(usedPercent: 42.5, windowSize: 1_000_000, estimated: false),
        skin: "sprig", eventTime: 1_760_000_000_000, startedAt: 1_759_990_000_000, tracked: true,
        limits: BridgeLimits(fiveHour: RateWindow(usedPercentage: 12.5, resetsAt: 1_760_003_600_000), sevenDay: nil, updatedAt: 1_760_000_000_000),
        capabilities: BridgeCapabilities(canSay: true, canAnswer: true, canInterrupt: false, readOnlyReason: "x")
    )
    let minimal = BridgeSession(
        id: "s2", name: "n", source: .other, state: .idle, cwd: "/tmp",
        skin: "sprig", eventTime: 1, startedAt: 2, tracked: false
    )
    // Captured from the synthesized `Codable` before `init(from:)` was written by hand.
    #expect(String(decoding: try encoder.encode(full), as: UTF8.self) == #"{"activity":"bash","branch":"main","capabilities":{"canAnswer":true,"canInterrupt":false,"canSay":true,"readOnlyReason":"x"},"context":{"estimated":false,"usedPercent":42.5,"windowSize":1000000},"cwd":"~/CODESPACE/clawd","detail":"Bash: swift test","eventTime":1760000000000,"id":"s1","limits":{"fiveHour":{"resetsAt":1760003600000,"usedPercentage":12.5},"updatedAt":1760000000000},"model":"Opus 5.5","name":"critter","skin":"sprig","source":"codex_desktop","startedAt":1759990000000,"state":"waiting","tracked":true}"#)
    #expect(String(decoding: try encoder.encode(minimal), as: UTF8.self) == #"{"cwd":"/tmp","eventTime":1,"id":"s2","name":"n","skin":"sprig","source":"other","startedAt":2,"state":"idle","tracked":false}"#)
}

/// The hand-written `init(from:)` reads back everything the synthesized encoding writes, the session's own
/// `limits` and `capabilities` (with its `readOnlyReason`) included.
@Test func aSessionWithEveryFieldSetRoundTrips() throws {
    let full = BridgeSession(
        id: "s1", name: "critter", source: .codexDesktop, state: .waiting,
        detail: "Bash: swift test", activity: "bash", cwd: "~/CODESPACE/clawd", branch: "main",
        model: "Opus 5.5", context: BridgeContext(usedPercent: 42.5, windowSize: 1_000_000, estimated: true),
        skin: "sprig", eventTime: 1_760_000_000_000, startedAt: 1_759_990_000_000, tracked: true,
        limits: BridgeLimits(
            fiveHour: RateWindow(usedPercentage: 12.5, resetsAt: 1_760_003_600_000),
            sevenDay: RateWindow(usedPercentage: 61, resetsAt: 1_760_400_000_000),
            updatedAt: 1_760_000_000_000
        ),
        capabilities: BridgeCapabilities(canSay: true, canAnswer: true, canInterrupt: true, readOnlyReason: "只读：会话在别处")
    )
    let decoded = try JSONDecoder().decode(BridgeSession.self, from: try JSONEncoder().encode(full))
    #expect(decoded == full)
    #expect(decoded.limits?.sevenDay?.usedPercentage == 61)
    #expect(decoded.capabilities?.readOnlyReason == "只读：会话在别处")
}
