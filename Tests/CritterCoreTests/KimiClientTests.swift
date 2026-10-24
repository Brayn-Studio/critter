import Foundation
import Testing
@testable import CritterCore

// `KimiClient` against a fake transport: the tests play Kimi Code's server, replaying frames and
// REST bodies shaped from the spike (design spec, "Kimi Code 1.1.2"). Nothing here talks to a
// real Kimi Code.

private final class FakeKimiTransport: KimiTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var onFrame: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var _connects: [(port: Int, token: String)] = []
    private var _sent: [JSONValue] = []
    private var _requests: [(method: String, path: String, body: JSONValue?)] = []
    private var _respond: @Sendable (_ method: String, _ path: String) -> Data? = { _, _ in ok(items: []) }
    /// What the "server" answers a REST call with; nil is a transport error.
    var respond: @Sendable (_ method: String, _ path: String) -> Data? {
        get { lock.withLock { _respond } }
        set { lock.withLock { _respond = newValue } }
    }

    var connects: [(port: Int, token: String)] { lock.withLock { _connects } }
    var sent: [JSONValue] { lock.withLock { _sent } }
    var requests: [(method: String, path: String, body: JSONValue?)] { lock.withLock { _requests } }
    func sent(_ type: String) -> [JSONValue] { sent.filter { $0["type"]?.stringValue == type } }
    func requested(_ path: String) -> Bool { requests.contains { $0.path == path } }

    func connect(port: Int, token: String, onFrame: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        lock.withLock {
            _connects.append((port, token))
            self.onFrame = onFrame
            self.onClose = onClose
        }
    }
    func send(_ data: Data) {
        let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        lock.withLock { if let value { _sent.append(value) } }
    }
    func close() { lock.withLock { onFrame = nil; onClose = nil } }
    func request(port: Int, token: String, method: String, path: String, body: Data?, completion: @escaping @Sendable (Data?) -> Void) {
        let decoded = body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        lock.withLock { _requests.append((method, path, decoded)) }
        let reply = respond(method, path)
        DispatchQueue.global().async { completion(reply) }
    }

    func deliver(_ json: String) {
        let handler = lock.withLock { onFrame }
        handler?(Data(json.utf8))
    }
    func dropConnection() {
        let handler = lock.withLock { onClose }
        handler?()
    }
}

private func ok(items: [Any]) -> Data {
    ok(data: ["items": items])
}
private func ok(data: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: ["code": 0, "msg": "success", "data": data, "request_id": "r1"])
}
private func failure(_ code: Int) -> Data {
    try! JSONSerialization.data(withJSONObject: ["code": code, "msg": "approval approval_1 not found", "data": NSNull(), "request_id": "r2"])
}

private func eventually(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(5_000)
    }
    return condition()
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}

private let sessionsPath = "/api/v1/sessions?busy=false&include_archive=false&exclude_empty=true&archived_only=false&page_size=100"
/// Kimi's `busy` query parameter is a filter: the busy sessions only come back with `busy=true`.
private let busySessionsPath = "/api/v1/sessions?busy=true&include_archive=false&exclude_empty=true&archived_only=false&page_size=100"
private let approvalsPath = "/api/v1/sessions/session_1/approvals?status=pending"
private let questionsPath = "/api/v1/sessions/session_1/questions?status=pending"
private let messagesPath = "/api/v1/sessions/session_1/messages?role=assistant&page_size=20"
private func session1() -> [String: Any] { ["id": "session_1", "workspace_id": "wd_app_8f0d97011d37", "title": "t", "busy": false,
                                       "main_turn_active": false, "pending_interaction": "none", "metadata": ["cwd": "/work/app"]] }
private func approvalItem() -> [String: Any] { [
    "approval_id": "approval_1", "session_id": "session_1", "agent_id": "main", "turn_id": 0, "tool_call_id": "tc_1",
    "tool_name": "Bash", "action": "run command", "tool_input_display": ["kind": "command", "command": "rm -rf x"],
    "created_at": "2026-10-24T17:52:10.000Z", "expires_at": "2026-10-24T18:52:10.000Z",
] }
private let hello = #"{"type":"server_hello","timestamp":"2026-10-24T17:52:09.379Z","payload":{"ws_connection_id":"conn_1","protocol_version":2,"heartbeat_ms":10000,"max_event_buffer_size":1000,"capabilities":{"event_batching":false,"compression":false}}}"#
private let busy = #"{"type":"event.session.work_changed","seq":6,"session_id":"session_1","payload":{"type":"event.session.work_changed","busy":true,"main_turn_active":true,"pending_interaction":"none","agentId":"main","sessionId":"session_1"}}"#
private let desktopApp: @Sendable (Int32) -> String? = { _ in "/Applications/Kimi Code.app/Contents/MacOS/Kimi Code" }

private struct Harness {
    let dir: URL
    let paths: CritterPaths
    let store: StateStore
    let transport = FakeKimiTransport()
    let changes = Counter()
    let client: KimiClient

    init(pid: Int32 = 4242, port: Int = 63812, alive: @escaping @Sendable (Int32) -> Bool = { $0 == 4242 }, writeInstance: Bool = true) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-client-" + UUID().uuidString)
        paths = CritterPaths(critterHome: dir.appendingPathComponent("critter"), claudeHome: dir.appendingPathComponent("claude"),
                             kimiHome: dir.appendingPathComponent("kimi"))
        store = StateStore(paths: paths)
        try FileManager.default.createDirectory(at: paths.kimiInstancesDir, withIntermediateDirectories: true)
        try Data("secret-token\n".utf8).write(to: paths.kimiTokenFile)
        let changes = changes
        client = KimiClient(paths: paths, transport: transport, now: { Int64(Date().timeIntervalSince1970 * 1000) },
                            isAlive: alive, executablePath: desktopApp, startTime: { _ in 77 }, onChange: { changes.bump() })
        if writeInstance { try instance(pid: pid, port: port) }
    }

    func instance(pid: Int32, port: Int, name: String = "01M5QFFVZFNP8MREJ64FH554D2") throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let body: [String: Any] = ["server_id": name, "pid": pid, "host": "127.0.0.1", "port": port,
                                   "started_at": now - 1_000, "heartbeat_at": now, "host_version": "2.3.0"]
        try JSONSerialization.data(withJSONObject: body).write(to: paths.kimiInstancesDir.appendingPathComponent(name + ".json"))
    }

    /// Connected, `session_1` listed (idle) and then busy: admitted and subscribed.
    func admitted() -> Bool {
        client.start()
        guard eventually(3, { transport.connects.count == 1 }) else { return false }
        transport.deliver(hello)
        guard eventually(3, { client.trackedSessionIDs.contains("session_1") }) else { return false }
        transport.deliver(busy)
        return eventually { store.read(sessionId: "kimi-session_1") != nil && transport.requested(questionsPath) }
    }

    func finish() {
        client.stop()
        _ = eventually(0.2) { false }
        try? FileManager.default.removeItem(at: dir)
    }
}

/// Plays the server: the session list filtered by `busy` as Kimi Code filters it.
private func respondWithSession(_ transport: FakeKimiTransport, sessions: [[String: Any]] = [session1()], approvals: [Any] = [],
                                messages: [Any] = [], post: Data? = nil) {
    let idle = ok(items: sessions.filter { $0["busy"] as? Bool != true }), working = ok(items: sessions.filter { $0["busy"] as? Bool == true })
    let approvals = ok(items: approvals), messages = ok(items: messages), empty = ok(items: [])
    transport.respond = { method, path in
        if method == "POST" { return post }
        switch path {
        case sessionsPath: return idle
        case busySessionsPath: return working
        case approvalsPath: return approvals
        case messagesPath: return messages
        default: return empty
        }
    }
}

@Test func kimiClientConnectsToLiveInstance() throws {
    let h = try Harness()
    defer { h.finish() }
    h.client.start()
    #expect(eventually { h.transport.connects.count == 1 })
    #expect(h.transport.connects.first?.port == 63812)
    #expect(h.transport.connects.first?.token == "secret-token")
    h.transport.deliver(hello)
    #expect(eventually { h.transport.requested(sessionsPath) })
    let helloFrame = try #require(h.transport.sent("client_hello").first)
    #expect(helloFrame["payload"] == .object(["client_id": .string("critter")]))
    #expect(helloFrame["id"]?.stringValue != nil)
    #expect(h.client.statusText == "已连接 Kimi Code")
}

@Test func kimiClientAnswersPingWithPong() throws {
    let h = try Harness()
    defer { h.finish() }
    h.client.start()
    #expect(eventually { h.transport.connects.count == 1 })
    h.transport.deliver(hello)
    h.transport.deliver(#"{"type":"ping","timestamp":"2026-10-24T17:52:19.379Z","payload":{"nonce":"n1"}}"#)
    #expect(eventually { !h.transport.sent("pong").isEmpty })
    #expect(h.transport.sent("pong").first == .object(["type": .string("pong"), "payload": .object(["nonce": .string("n1")])]))
}

@Test func kimiClientWorkChangedBusyAdmitsAndSubscribes() throws {
    let h = try Harness()
    defer { h.finish() }
    respondWithSession(h.transport, approvals: [approvalItem()])
    #expect(h.admitted())
    let record = try #require(h.store.read(sessionId: "kimi-session_1"))
    #expect(record.cwd == "/work/app")
    #expect(record.entrypoint == "kimi-desktop")
    #expect(record.claudePid == 4242)
    #expect(record.claudeStartTime == 77)
    let subscribe = try #require(h.transport.sent("subscribe").first)
    #expect(subscribe["payload"]?["session_ids"] == .array([.string("session_1")]))
    #expect(h.transport.requested(approvalsPath))
    #expect(eventually { h.client.requests.map(\.pending.requestId) == ["kimi-approval_1"] })
    // The pending approval also tells the pet what it waits on.
    #expect(eventually { h.store.read(sessionId: "kimi-session_1")?.state == .waiting })
    #expect(h.store.read(sessionId: "kimi-session_1")?.detail == "需要你确认：Bash(rm -rf x)")
    #expect(h.client.capabilities["kimi-session_1"] == BridgeCapabilities(
        canSay: false, canAnswer: true, canInterrupt: false, readOnlyReason: "Kimi Code 会话暂不支持从手机发消息"))
}

@Test func kimiClientIdleListedSessionsAreNotPets() throws {
    let h = try Harness()
    defer { h.finish() }
    respondWithSession(h.transport)
    h.client.start()
    #expect(eventually { h.transport.connects.count == 1 })
    h.transport.deliver(hello)
    #expect(eventually { h.client.trackedSessionIDs.contains("session_1") })
    #expect(h.store.read(sessionId: "kimi-session_1") == nil)
    #expect(h.transport.sent("subscribe").isEmpty)
}

@Test func kimiClientCompletedTurnFetchesLastAssistantMessage() throws {
    let h = try Harness()
    defer { h.finish() }
    respondWithSession(h.transport, messages: [
        ["id": "m2", "session_id": "session_1", "role": "assistant", "created_at": "2026-10-24T18:00:00.000Z",
         "content": [["type": "text", "text": "改好了。测试也过了。"]]],
        ["id": "m1", "session_id": "session_1", "role": "assistant", "created_at": "2026-10-24T17:00:00.000Z",
         "content": [["type": "text", "text": "Older reply."]]],
    ])
    #expect(h.admitted())
    #expect(eventually { h.store.read(sessionId: "kimi-session_1")?.state == .running })
    h.transport.deliver(#"{"type":"turn.ended","seq":14,"session_id":"session_1","payload":{"type":"turn.ended","agentId":"main","turnId":0,"reason":"completed"}}"#)
    #expect(eventually { h.transport.requested(messagesPath) })
    #expect(eventually { h.store.read(sessionId: "kimi-session_1")?.detail == "改好了。" })
    #expect(h.store.read(sessionId: "kimi-session_1")?.state == .done)
}

@Test func kimiLastMessageWithoutTimesIsTheLastItem() {
    let items = try! JSONDecoder().decode(JSONValue.self, from: Data(#"""
    [{"content":[{"type":"text","text":"first"}]},{"content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"Second one."},{"type":"text","text":"More"}]}]
    """#.utf8))
    #expect(KimiClient.lastAssistantText(items.ipcArray ?? []) == "Second one.\nMore")
}

@Test func kimiClientAnswerApprovalPostsDecision() throws {
    let h = try Harness()
    defer { h.finish() }
    respondWithSession(h.transport, approvals: [approvalItem()], post: ok(data: ["resolved": true, "resolved_at": "2026-10-24T17:53:00.000Z"]))
    #expect(h.admitted())
    #expect(eventually { !h.client.requests.isEmpty })
    #expect(h.client.answer(AnswerPayload(decision: "allow"), requestID: "kimi-approval_1") == .accepted)
    let post = try #require(h.transport.requests.first { $0.method == "POST" })
    #expect(post.path == "/api/v1/sessions/session_1/approvals/approval_1")
    #expect(post.body == .object(["decision": .string("approved")]))
    #expect(h.client.requests.isEmpty)
}

@Test func kimiClientAnswerAfterResolvedReportsAlreadyAnswered() throws {
    let h = try Harness()
    defer { h.finish() }
    respondWithSession(h.transport, approvals: [approvalItem()], post: failure(40404))
    #expect(h.admitted())
    #expect(eventually { !h.client.requests.isEmpty })
    #expect(h.client.answer(AnswerPayload(decision: "deny", message: "no"), requestID: "kimi-approval_1") == .alreadyAnswered)
    #expect(h.transport.requests.first { $0.method == "POST" }?.body == .object(["decision": .string("rejected"), "feedback": .string("no")]))
    #expect(h.client.requests.isEmpty)
    #expect(h.client.answer(AnswerPayload(decision: "allow"), requestID: "kimi-nope") == .alreadyAnswered)
}

@Test func kimiClientAnswerTransportErrorFails() throws {
    let h = try Harness()
    defer { h.finish() }
    respondWithSession(h.transport, approvals: [approvalItem()], post: nil)
    #expect(h.admitted())
    #expect(eventually { !h.client.requests.isEmpty })
    #expect(h.client.answer(AnswerPayload(decision: "allow"), requestID: "kimi-approval_1") == .failed)
    // Still there to answer again.
    #expect(h.client.requests.count == 1)
}

@Test func kimiClientResolvedEventRemovesRequest() throws {
    let h = try Harness()
    defer { h.finish() }
    respondWithSession(h.transport, approvals: [approvalItem()])
    #expect(h.admitted())
    #expect(eventually { !h.client.requests.isEmpty })
    let before = h.changes.value
    h.transport.deliver(#"{"type":"event.approval.resolved","seq":9,"session_id":"session_1","payload":{"type":"event.approval.resolved","approval_id":"approval_1","decision":"approved","sessionId":"session_1"}}"#)
    #expect(eventually { h.client.requests.isEmpty })
    #expect(eventually { h.changes.value > before })
    #expect(eventually { h.store.read(sessionId: "kimi-session_1")?.state == .running })
}

@Test func kimiClientServerRestartReplacesOwnerAndDropsOldRecords() throws {
    let alive = Counter() // 0: the first server lives; 1: only the second one does
    let h = try Harness(pid: 1111, port: 5000, alive: { pid in alive.value == 0 ? pid == 1111 : pid == 2222 })
    defer { h.finish() }
    // A record left by an earlier server, and one by a Claude session that must stay.
    try h.store.update(sessionId: "kimi-session_old") { _ in
        .write(SessionRecord(schema: 1, sessionId: "kimi-session_old", cwd: "/w", transcriptPath: nil, state: .done, detail: nil,
                             lastEvent: "Kimi:turn.ended", eventTime: 1, createdAt: 1, claudePid: 999, claudeStartTime: 1, entrypoint: "kimi-desktop"))
    }
    try h.store.update(sessionId: "claude-1") { _ in
        .write(SessionRecord(schema: 1, sessionId: "claude-1", cwd: "/w", transcriptPath: nil, state: .running, detail: nil,
                             lastEvent: "PreToolUse", eventTime: 1, createdAt: 1, claudePid: 999, claudeStartTime: 1, entrypoint: "cli"))
    }
    respondWithSession(h.transport)
    h.client.start()
    #expect(eventually { h.transport.connects.count == 1 })
    #expect(eventually { h.store.read(sessionId: "kimi-session_old") == nil })
    #expect(h.store.read(sessionId: "claude-1") != nil)
    h.transport.deliver(hello)
    #expect(eventually { h.client.trackedSessionIDs.contains("session_1") })
    h.transport.deliver(busy)
    #expect(eventually { h.store.read(sessionId: "kimi-session_1")?.claudePid == 1111 })

    // Kimi Code restarts: a new server, pid and port, and a new token.
    try FileManager.default.removeItem(at: h.paths.kimiInstancesDir.appendingPathComponent("01M5QFFVZFNP8MREJ64FH554D2.json"))
    try h.instance(pid: 2222, port: 6000, name: "01M5QNEW")
    try Data("token-2".utf8).write(to: h.paths.kimiTokenFile)
    alive.bump()
    h.client.refresh()
    #expect(eventually { h.transport.connects.count == 2 })
    #expect(h.transport.connects.last?.port == 6000)
    #expect(h.transport.connects.last?.token == "token-2")
    #expect(eventually { h.store.read(sessionId: "kimi-session_1") == nil })
    #expect(h.store.read(sessionId: "claude-1") != nil)
}

@Test func kimiClientNoInstanceMeansNoRecordsAndReason() throws {
    let h = try Harness()
    defer { h.finish() }
    respondWithSession(h.transport)
    #expect(h.admitted())
    try FileManager.default.removeItem(at: h.paths.kimiInstancesDir)
    h.client.refresh()
    #expect(eventually { h.store.read(sessionId: "kimi-session_1") == nil })
    #expect(h.client.statusText == "尚未连接 Kimi Code")
    #expect(h.client.capabilities["kimi-session_1"] == BridgeCapabilities(readOnlyReason: "尚未连接 Kimi Code"))
    #expect(h.client.requests.isEmpty)
}

@Test func kimiClientWithoutKimiNeverConnects() throws {
    let h = try Harness(writeInstance: false)
    defer { h.finish() }
    try h.store.update(sessionId: "kimi-session_9") { _ in
        .write(SessionRecord(schema: 1, sessionId: "kimi-session_9", cwd: "/w", transcriptPath: nil, state: .idle, detail: nil,
                             lastEvent: "Kimi:turn.ended", eventTime: 1, createdAt: 1, claudePid: 4242, claudeStartTime: 1, entrypoint: "kimi-cli"))
    }
    h.client.start()
    #expect(eventually { h.store.read(sessionId: "kimi-session_9") == nil })
    #expect(h.transport.connects.isEmpty)
    #expect(h.client.statusText == "尚未连接 Kimi Code")
}

@Test func kimiClientArchivedOrDeletedSessionRemovesRecord() throws {
    for type in ["event.session.archived", "event.session.deleted"] {
        let h = try Harness()
        defer { h.finish() }
        respondWithSession(h.transport, approvals: [approvalItem()])
        #expect(h.admitted())
        #expect(eventually { !h.client.requests.isEmpty })
        h.transport.deliver(#"{"type":"\#(type)","seq":14,"session_id":"__global__","payload":{"type":"\#(type)","workspace_id":"wd_app_8f0d97011d37","agentId":"main","sessionId":"session_1"}}"#)
        #expect(eventually { h.store.read(sessionId: "kimi-session_1") == nil })
        #expect(h.client.requests.isEmpty)
        #expect(!h.client.trackedSessionIDs.contains("session_1"))
    }
}

@Test func kimiClientResyncRelistsAndRefetchesPending() throws {
    let h = try Harness()
    defer { h.finish() }
    respondWithSession(h.transport)
    #expect(h.admitted())
    let lists = h.transport.requests.filter { $0.path == sessionsPath }.count
    let fetches = h.transport.requests.filter { $0.path == approvalsPath }.count
    respondWithSession(h.transport, approvals: [approvalItem()])
    h.transport.deliver(#"{"type":"resync_required","timestamp":"2026-10-24T17:55:00.000Z","payload":{"session_id":"session_1","reason":"buffer_overflow","current_seq":40}}"#)
    #expect(eventually { h.transport.requests.filter { $0.path == sessionsPath }.count > lists })
    #expect(eventually { h.transport.requests.filter { $0.path == approvalsPath }.count > fetches })
    #expect(eventually { h.client.requests.map(\.pending.requestId) == ["kimi-approval_1"] })
}

@Test func kimiClientDroppedConnectionReconnects() throws {
    let h = try Harness()
    defer { h.finish() }
    respondWithSession(h.transport)
    #expect(h.admitted())
    h.transport.dropConnection()
    #expect(eventually { h.client.statusText == "尚未连接 Kimi Code" })
    #expect(eventually(4) { h.transport.connects.count == 2 })
}

/// A session in the middle of a turn, waiting on an approval: re-lists (a resync, a reconnect)
/// must find it on the busy page and keep its pet and its phone request.
@Test func kimiClientBusySessionSurvivesResyncAndReconnect() throws {
    let h = try Harness()
    defer { h.finish() }
    var working = session1()
    working["busy"] = true; working["main_turn_active"] = true; working["pending_interaction"] = "approval"
    var other = session1()
    other["id"] = "session_2"
    respondWithSession(h.transport, sessions: [working, other], approvals: [approvalItem()])
    h.client.start()
    #expect(eventually { h.transport.connects.count == 1 })
    h.transport.deliver(hello)
    #expect(eventually { h.store.read(sessionId: "kimi-session_1")?.state == .waiting })
    #expect(eventually { h.client.requests.map(\.pending.requestId) == ["kimi-approval_1"] })
    #expect(h.client.trackedSessionIDs == ["session_1", "session_2"])
    #expect(h.store.read(sessionId: "kimi-session_2") == nil)

    func lists() -> Int { h.transport.requests.filter { $0.path == sessionsPath || $0.path == busySessionsPath }.count }
    var before = lists()
    h.transport.deliver(#"{"type":"resync_required","timestamp":"2026-10-24T17:55:00.000Z","payload":{"session_id":"session_1","reason":"buffer_overflow","current_seq":40}}"#)
    #expect(eventually { lists() >= before + 2 })
    _ = eventually(0.2) { false }
    #expect(h.store.read(sessionId: "kimi-session_1")?.state == .waiting)
    #expect(h.client.requests.map(\.pending.requestId) == ["kimi-approval_1"])

    h.transport.dropConnection()
    #expect(eventually(4) { h.transport.connects.count == 2 })
    before = lists()
    h.transport.deliver(hello)
    #expect(eventually { lists() >= before + 2 })
    #expect(eventually { h.client.requests.map(\.pending.requestId) == ["kimi-approval_1"] })
    _ = eventually(0.2) { false }
    #expect(h.store.read(sessionId: "kimi-session_1")?.state == .waiting)
    #expect(h.client.trackedSessionIDs == ["session_1", "session_2"])
}

/// A failed page means the list isn't complete: nothing is forgotten for being missing from it.
@Test func kimiClientFailedPageForgetsNothing() throws {
    let h = try Harness()
    defer { h.finish() }
    respondWithSession(h.transport)
    #expect(h.admitted())
    let idle = ok(items: [])
    h.transport.respond = { _, path in path == sessionsPath ? idle : nil }
    h.transport.deliver(#"{"type":"resync_required","timestamp":"2026-10-24T17:55:00.000Z","payload":{"session_id":"session_1","reason":"buffer_overflow","current_seq":40}}"#)
    #expect(eventually { h.transport.requests.filter { $0.path == busySessionsPath }.count >= 2 })
    _ = eventually(0.2) { false }
    #expect(h.store.read(sessionId: "kimi-session_1") != nil)
    #expect(h.client.trackedSessionIDs.contains("session_1"))
}
