import Foundation
import Testing
@testable import CritterCore

// Fixtures are shaped from the Kimi Code 1.1.2 spike (design spec, "Spike results"): frames are
// `{type, seq, session_id, timestamp, payload}`, with the type repeated inside the payload.

private func frame(_ type: String, session: String? = "session_1", _ payload: [String: Any] = [:]) -> KimiFrame {
    var body = payload
    body["type"] = type
    var root: [String: Any] = ["type": type, "seq": 3, "timestamp": "2026-10-24T17:52:09.976Z", "payload": body]
    if let session { root["session_id"] = session }
    let data = try! JSONSerialization.data(withJSONObject: root)
    return KimiFrame.decode(data)!
}

private func json(_ text: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

private func state(_ petState: PetState, admitted: Bool = true, detail: String? = nil, activity: WorkActivity? = nil) -> KimiSessionState {
    KimiSessionState(id: "session_1", cwd: "/work/app", title: "t", state: petState, detail: detail,
                     activity: activity, admitted: admitted, lastEvent: "KimiSession")
}

private let running = state(.running, detail: BubbleText.thinking, activity: .think)

// MARK: - Discovery

private func instanceFile(_ dir: URL, _ name: String, pid: Int32, port: Int, started: Int64, heartbeat: Int64) throws {
    let body: [String: Any] = ["server_id": name, "pid": pid, "host": "127.0.0.1", "port": port,
                               "started_at": started, "heartbeat_at": heartbeat, "host_version": "2.3.0"]
    try JSONSerialization.data(withJSONObject: body).write(to: dir.appendingPathComponent(name + ".json"))
}

@Test func kimiDiscoveryPicksTheLiveInstanceAndSkipsMalformedFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try instanceFile(dir, "dead", pid: 111, port: 1000, started: 5_000, heartbeat: 99_000)
    try instanceFile(dir, "live", pid: 222, port: 2000, started: 4_000, heartbeat: 99_000)
    try Data("{not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
    try Data(#"{"server_id":"x"}"#.utf8).write(to: dir.appendingPathComponent("partial.json"))

    let all = KimiDiscovery.instances(in: dir)
    #expect(all.count == 2)
    let live = KimiDiscovery.live(all, now: 100_000, isAlive: { $0 == 222 })
    #expect(live == KimiInstance(serverId: "live", pid: 222, host: "127.0.0.1", port: 2000, startedAt: 4_000, heartbeatAt: 99_000))
}

@Test func kimiDiscoveryNewestStartWinsAndStaleHeartbeatIsNotLive() {
    let old = KimiInstance(serverId: "a", pid: 1, host: "127.0.0.1", port: 1, startedAt: 1_000, heartbeatAt: 100_000)
    let new = KimiInstance(serverId: "b", pid: 2, host: "127.0.0.1", port: 2, startedAt: 2_000, heartbeatAt: 100_000)
    #expect(KimiDiscovery.live([old, new], now: 100_000, isAlive: { _ in true }) == new)
    #expect(KimiDiscovery.live([old], now: 160_000, isAlive: { _ in true }) == old)
    #expect(KimiDiscovery.live([old], now: 161_000, isAlive: { _ in true }) == nil)
    #expect(KimiDiscovery.instances(in: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")).isEmpty)
}

@Test func kimiPathsFollowKimiCodeHome() {
    let paths = CritterPaths.fromEnvironment(["HOME": "/Users/me", "KIMI_CODE_HOME": "/opt/kimi"])
    #expect(paths.kimiHome.path == "/opt/kimi")
    #expect(paths.kimiInstancesDir.path == "/opt/kimi/server/instances")
    #expect(paths.kimiTokenFile.path == "/opt/kimi/server.token")
    #expect(CritterPaths.fromEnvironment(["HOME": "/Users/me"]).kimiHome.path == "/Users/me/.kimi-code")
    // Kimi's ids carry underscores; path separators and dots still never pass.
    #expect(paths.stateFile(sessionId: "kimi-session_1")?.lastPathComponent == "kimi-session_1.json")
    #expect(paths.stateFile(sessionId: "kimi-../x") == nil)
}

// MARK: - Frames

@Test func kimiFrameTakesTypeAndSessionFromTheTopLevel() {
    let data = Data(#"{"type":"turn.started","seq":5,"session_id":"session_1","payload":{"type":"other","turnId":0}}"#.utf8)
    let decoded = KimiFrame.decode(data)
    #expect(decoded?.type == "turn.started")
    #expect(decoded?.sessionId == "session_1")
    #expect(decoded?.payload["turnId"] == .number(0))
    let global = KimiFrame.decode(Data(#"{"type":"event.session.deleted","session_id":"__global__","payload":{"sessionId":"session_9"}}"#.utf8))
    #expect(global?.sessionId == "session_9")
    let created = KimiFrame.decode(Data(#"{"type":"event.session.created","session_id":"__global__","payload":{"session":{"id":"session_7"}}}"#.utf8))
    #expect(created?.sessionId == "session_7")
    let hello = KimiFrame.decode(Data(#"{"type":"server_hello","payload":{"protocol_version":2}}"#.utf8))
    #expect(hello?.type == "server_hello" && hello?.sessionId == nil)
    #expect(KimiFrame.decode(Data(#"{"payload":{}}"#.utf8)) == nil)
    #expect(KimiFrame.decode(Data("nope".utf8)) == nil)
}

// MARK: - Initial state

@Test func idleSessionsAtConnectAreNotAdmitted() {
    let idle = KimiReducer.initial(session: json(#"{"id":"session_1","title":"t","busy":false,"pending_interaction":"none","metadata":{"cwd":"/work/app"}}"#))
    #expect(idle?.admitted == false)
    #expect(idle?.state == .idle)
    #expect(idle?.cwd == "/work/app")
    let busy = KimiReducer.initial(session: json(#"{"id":"session_1","title":"t","busy":true,"pending_interaction":"none","metadata":{"cwd":"/work/app"}}"#))
    #expect(busy?.admitted == true)
    #expect(busy?.state == .running)
    #expect(busy?.activity == .think)
    #expect(busy?.title == "t")
    #expect(KimiReducer.initial(session: json(#"{"id":"session_1","busy":true}"#)) == nil)
}

// MARK: - Reducer

@Test func kimiTurnStartedRunsAndThinks() {
    let next = KimiReducer.reduce(state(.idle, admitted: false), frame: frame("turn.started", ["turnId": 0, "agentId": "main"]))
    #expect(next.admitted)
    #expect(next.state == .running)
    #expect(next.activity == .think)
    #expect(next.detail == BubbleText.thinking)
    #expect(next.lastEvent == "turn.started")
}

@Test func kimiToolCallsPickActivityAndSummary() {
    let bash = KimiReducer.reduce(running, frame: frame("tool.call.started", ["name": "Bash", "args": ["command": "npm test"]]))
    #expect(bash.state == .running)
    #expect(bash.activity == .bash)
    #expect(bash.detail == ToolSummary.activity(toolName: "Bash", input: json(#"{"command":"npm test"}"#)))
    #expect(KimiReducer.reduce(running, frame: frame("tool.call.started", ["name": "FetchURL", "args": ["url": "https://x.dev"]])).activity == .read)
    #expect(KimiReducer.reduce(running, frame: frame("tool.call.started", ["name": "AgentSwarm", "args": [:]])).activity == .juggle)
    #expect(KimiReducer.reduce(running, frame: frame("tool.call.started", ["name": "Agent", "args": [:]])).activity == .juggle)
    let edit = KimiReducer.reduce(running, frame: frame("tool.call.started", ["name": "Edit", "args": ["path": "/work/app/a.swift"]]))
    #expect(edit.activity == .laptop)
    #expect(edit.detail == ToolSummary.activity(toolName: "Edit", input: json(#"{"file_path":"/work/app/a.swift"}"#)))
    #expect(edit.detail == "编辑 a.swift")
}

@Test func kimiToolResultGoesBackToThinking() {
    let busy = state(.running, detail: "Bash: npm test", activity: .bash)
    let next = KimiReducer.reduce(busy, frame: frame("tool.result", ["toolCallId": "c1", "output": "ok"]))
    #expect(next.state == .running)
    #expect(next.activity == .think)
}

@Test func kimiApprovalAndQuestionWait() {
    let approval = KimiReducer.reduce(running, frame: frame("event.approval.requested", [
        "approval_id": "approval_1", "tool_name": "Bash", "tool_input_display": ["kind": "command", "command": "rm -rf x"],
    ]))
    #expect(approval.state == .waiting)
    #expect(approval.activity == nil)
    #expect(approval.detail == ToolSummary.permission(toolName: "Bash", input: json(#"{"command":"rm -rf x"}"#)))
    let question = KimiReducer.reduce(running, frame: frame("event.question.requested", ["question_id": "qq", "questions": []]))
    #expect(question.state == .waiting)
    #expect(question.detail == BubbleText.askQuestion(entrypoint: "kimi-desktop"))
    #expect(question.detail == "Kimi 在问你问题")
    for type in ["event.approval.resolved", "event.question.answered", "event.question.dismissed"] {
        let resumed = KimiReducer.reduce(question, frame: frame(type, ["question_id": "qq", "approval_id": "approval_1"]))
        #expect(resumed.state == .running)
        #expect(resumed.activity == .think)
    }
}

@Test func kimiToolCallStartedKeepsWaiting() {
    let waiting = KimiReducer.reduce(running, frame: frame("event.approval.requested", ["approval_id": "a1", "tool_name": "Bash"]))
    let next = KimiReducer.reduce(waiting, frame: frame("tool.call.started", ["name": "Read", "args": ["path": "/work/app/a.swift"]]))
    #expect(next.state == .waiting)
    #expect(next.detail == waiting.detail)
    #expect(next.activity == nil)
}

@Test func kimiResolvingOneRequestKeepsWaitingWhileAnotherIsOpen() {
    var s = KimiReducer.reduce(running, frame: frame("event.approval.requested", ["approval_id": "a1", "tool_name": "Bash"]))
    s = KimiReducer.reduce(s, frame: frame("event.approval.requested", ["approval_id": "a2", "tool_name": "Edit"]))
    s = KimiReducer.reduce(s, frame: frame("event.question.requested", ["question_id": "q1", "questions": []]))
    s = KimiReducer.reduce(s, frame: frame("event.approval.resolved", ["approval_id": "a1"]))
    #expect(s.state == .waiting)
    s = KimiReducer.reduce(s, frame: frame("event.approval.resolved", ["approval_id": "a2"]))
    #expect(s.state == .waiting)
    #expect(s.detail == BubbleText.askQuestion(entrypoint: "kimi-desktop"))
    s = KimiReducer.reduce(s, frame: frame("event.question.dismissed", ["question_id": "q1"]))
    #expect(s.state == .running)
    #expect(s.activity == .think)
}

@Test func kimiTurnEndedByReason() {
    let done = KimiReducer.reduce(running, frame: frame("turn.ended", ["reason": "completed"]))
    #expect(done.state == .done)
    #expect(done.detail == BubbleText.done)
    #expect(done.activity == nil)
    let message = "403 Your current subscription does not have access to Kimi Code right now. Upgrade your plan."
    let failed = KimiReducer.reduce(running, frame: frame("turn.ended", ["reason": "failed", "error": ["code": "provider.auth_error", "message": message]]))
    #expect(failed.state == .error)
    #expect(failed.detail == BubbleText.errorPrefix + ToolSummary.truncate(message, max: 50))
    for reason in ["cancelled", "blocked"] {
        let stopped = KimiReducer.reduce(running, frame: frame("turn.ended", ["reason": reason]))
        #expect(stopped.state == .idle)
        #expect(stopped.detail == nil)
        #expect(stopped.activity == nil)
    }
}

@Test func kimiSubagentTurnsDoNotEndTheSession() {
    let next = KimiReducer.reduce(running, frame: frame("turn.ended", ["reason": "completed", "agentId": "agent_7"]))
    #expect(next == running)
}

@Test func kimiUnknownFramesLeaveStateUnchanged() {
    #expect(KimiReducer.reduce(running, frame: frame("agent.status.updated", ["phase": ["kind": "running"]])) == running)
    #expect(KimiReducer.reduce(running, frame: frame("context.spliced", ["messages": []])) == running)
}

// MARK: - work_changed table (one test per row)

private func work(_ busy: Bool, _ pending: String = "none", reason: String? = nil) -> KimiFrame {
    var payload: [String: Any] = ["busy": busy, "main_turn_active": busy, "pending_interaction": pending]
    if let reason { payload["last_turn_reason"] = reason }
    return frame("event.session.work_changed", payload)
}

@Test func kimiWorkChangedBusyStartsIdleDoneErrorOrUnadmitted() {
    for start in [state(.idle), state(.done, detail: BubbleText.done), state(.error, detail: "出错了"), state(.idle, admitted: false)] {
        let next = KimiReducer.reduce(start, frame: work(true))
        #expect(next.admitted)
        #expect(next.state == .running)
        #expect(next.activity == .think)
    }
}

@Test func kimiWorkChangedPendingApprovalWaits() {
    let next = KimiReducer.reduce(running, frame: work(true, "approval"))
    #expect(next.state == .waiting)
    #expect(next.detail == "需要你确认")
    let already = state(.waiting, detail: "需要你确认：Bash(rm -rf x)")
    #expect(KimiReducer.reduce(already, frame: work(true, "approval")) == already)
}

@Test func kimiWorkChangedPendingQuestionWaits() {
    let next = KimiReducer.reduce(running, frame: work(true, "question"))
    #expect(next.state == .waiting)
    #expect(next.detail == "Kimi 在问你问题")
}

@Test func kimiWorkChangedNotBusyCompletedIsDone() {
    for start in [running, state(.waiting, detail: "需要你确认")] {
        let next = KimiReducer.reduce(start, frame: work(false, reason: "completed"))
        #expect(next.state == .done)
        #expect(next.detail == BubbleText.done)
        #expect(next.activity == nil)
    }
}

@Test func kimiWorkChangedNotBusyFailedIsError() {
    let next = KimiReducer.reduce(running, frame: work(false, reason: "failed"))
    #expect(next.state == .error)
    #expect(next.detail == "出错了")
}

@Test func kimiWorkChangedNotBusyCancelledOrUnknownIsIdle() {
    for reason in ["cancelled", nil] {
        let next = KimiReducer.reduce(running, frame: work(false, reason: reason))
        #expect(next.state == .idle)
        #expect(next.detail == nil)
    }
}

@Test func kimiWorkChangedOtherwiseLeavesStateUnchanged() {
    #expect(KimiReducer.reduce(running, frame: work(true)) == running)
    let done = state(.done, detail: "改好了。")
    #expect(KimiReducer.reduce(done, frame: work(false, reason: "completed")) == done)
    let idle = state(.idle)
    #expect(KimiReducer.reduce(idle, frame: work(false)) == idle)
    let unadmitted = state(.idle, admitted: false)
    #expect(KimiReducer.reduce(unadmitted, frame: work(false, reason: "completed")) == unadmitted)
}

// MARK: - Records

private let owner = KimiInstance(serverId: "s", pid: 4242, host: "127.0.0.1", port: 63812, startedAt: 1, heartbeatAt: 2)

@Test func kimiRecordCarriesOwnerAndKeepsCreation() {
    let first = KimiReducer.record(for: running, owner: owner, ownerStartTime: 77, entrypoint: "kimi-desktop", previous: nil, now: 1_000)
    #expect(first.schema == 1)
    #expect(first.sessionId == "kimi-session_1")
    #expect(first.cwd == "/work/app")
    #expect(first.state == .running)
    #expect(first.activity == "think")
    #expect(first.detail == BubbleText.thinking)
    #expect(first.claudePid == 4242)
    #expect(first.claudeStartTime == 77)
    #expect(first.entrypoint == "kimi-desktop")
    #expect(first.eventTime == 1_000 && first.createdAt == 1_000)
    let done = KimiReducer.reduce(running, frame: frame("turn.ended", ["reason": "completed"]))
    let second = KimiReducer.record(for: done, owner: owner, ownerStartTime: 77, entrypoint: "kimi-desktop", previous: first, now: 2_000)
    #expect(second.createdAt == 1_000)
    #expect(second.eventTime == 2_000)
    #expect(second.state == .done)
    // Nothing new: the record (and its event time) stays as it was.
    #expect(KimiReducer.record(for: done, owner: owner, ownerStartTime: 77, entrypoint: "kimi-desktop", previous: second, now: 3_000) == second)
}

@Test func kimiRecordKeepsASeenDoneAsSeen() {
    let done = KimiReducer.reduce(running, frame: frame("turn.ended", ["reason": "completed"]))
    var seen = KimiReducer.record(for: done, owner: owner, ownerStartTime: 77, entrypoint: "kimi-desktop", previous: nil, now: 1_000)
    seen.state = .idle; seen.detail = nil; seen.lastEvent = "Seen"; seen.eventTime = 1_500
    let again = KimiReducer.record(for: done, owner: owner, ownerStartTime: 77, entrypoint: "kimi-desktop", previous: seen, now: 2_000)
    #expect(again == seen)
}

// MARK: - Phone requests

private let approvalFrame = frame("event.approval.requested", [
    "approval_id": "approval_1", "session_id": "session_1", "agent_id": "main", "turn_id": 0, "tool_call_id": "tc_1",
    "tool_name": "Bash", "action": "run command", "tool_input_display": ["kind": "command", "command": "rm -rf x"],
    "created_at": "2026-10-24T17:52:10.000Z", "expires_at": "2026-10-24T18:52:10.000Z",
])

private func body(_ pair: (path: String, json: [String: Any])?) -> String? {
    guard let pair, let data = try? JSONSerialization.data(withJSONObject: pair.json, options: [.sortedKeys]) else { return nil }
    return pair.path + " " + String(decoding: data, as: UTF8.self)
}

@Test func kimiApprovalBecomesAPermissionRequest() throws {
    let request = try #require(KimiPhoneRequest(frame: approvalFrame, now: 5_000, ownerPid: 4242))
    #expect(request.pending.requestId == "kimi-approval_1")
    #expect(request.pending.kind == .permission)
    #expect(request.pending.toolName == "Bash")
    #expect(request.pending.input == json(#"{"command":"rm -rf x"}"#))
    #expect(request.pending.sessionId == "kimi-session_1")
    #expect(request.pending.hookPid == 4242)
    #expect(request.pending.expiresAt == .max)
    #expect(request.pending.createdAt == 5_000)
    #expect(request.kimiSessionId == "session_1")
    #expect(request.kimiId == "approval_1")
    #expect(!request.isQuestion)
    #expect(body(request.body(for: AnswerPayload(decision: "allow"))) == #"/api/v1/sessions/session_1/approvals/approval_1 {"decision":"approved"}"#)
    #expect(body(request.body(for: AnswerPayload(decision: "deny", message: "no"))) == #"/api/v1/sessions/session_1/approvals/approval_1 {"decision":"rejected","feedback":"no"}"#)
    #expect(body(request.body(for: AnswerPayload(decision: "deny"))) == #"/api/v1/sessions/session_1/approvals/approval_1 {"decision":"rejected"}"#)
    #expect(request.body(for: AnswerPayload(decision: "maybe")) == nil)
}

@Test func kimiApprovalDisplayKindsMapToInput() {
    let file = KimiPhoneRequest(frame: frame("event.approval.requested", [
        "approval_id": "a2", "tool_name": "Edit", "tool_input_display": ["kind": "diff", "path": "/w/a.swift", "before": "", "after": "x"],
    ]), now: 1, ownerPid: 1)
    #expect(file?.pending.input == json(#"{"file_path":"/w/a.swift"}"#))
    let url = KimiPhoneRequest(frame: frame("event.approval.requested", [
        "approval_id": "a3", "tool_name": "FetchURL", "tool_input_display": ["kind": "url_fetch", "url": "https://x.dev"],
    ]), now: 1, ownerPid: 1)
    #expect(url?.pending.input == json(#"{"url":"https://x.dev"}"#))
}

@Test func kimiRequestsWithUnsafeIdsAreRefused() {
    let bad = frame("event.approval.requested", ["approval_id": "../x", "tool_name": "Bash", "tool_input_display": ["kind": "command", "command": "ls"]])
    #expect(KimiPhoneRequest(frame: bad, now: 1, ownerPid: 1) == nil)
    let noSession = frame("event.approval.requested", session: nil, ["approval_id": "a1", "tool_name": "Bash"])
    #expect(KimiPhoneRequest(frame: noSession, now: 1, ownerPid: 1) == nil)
    #expect(KimiPhoneRequest(frame: frame("turn.started"), now: 1, ownerPid: 1) == nil)
}

private func questionFrame(multi: Bool = false) -> KimiFrame {
    frame("event.question.requested", [
        "question_id": "qq", "session_id": "session_1",
        "questions": [["id": "q_0", "question": "Which?", "header": "H",
                       "options": [["id": "opt_0_0", "label": "A"], ["id": "opt_0_1", "label": "B"]],
                       "multi_select": multi, "allow_other": true]],
    ])
}

@Test func kimiQuestionBecomesAnAskUserQuestion() throws {
    let request = try #require(KimiPhoneRequest(frame: questionFrame(), now: 5_000, ownerPid: 4242))
    #expect(request.pending.requestId == "kimi-qq")
    #expect(request.pending.kind == .question)
    #expect(request.pending.toolName == "AskUserQuestion")
    #expect(request.pending.summary == "Kimi 在问你问题")
    #expect(request.pending.input == json(#"{"questions":[{"question":"Which?","header":"H","multiSelect":false,"options":[{"label":"A"},{"label":"B"}]}]}"#))
    #expect(request.isQuestion)
    #expect(request.questions.count == 1)
    #expect(body(request.body(for: AnswerPayload(answers: ["Which?": "B"])))
            == #"/api/v1/sessions/session_1/questions/qq {"answers":{"q_0":{"kind":"single","option_id":"opt_0_1"}}}"#)
    #expect(body(request.body(for: AnswerPayload(answers: ["Which?": "something else"])))
            == #"/api/v1/sessions/session_1/questions/qq {"answers":{"q_0":{"kind":"other","text":"something else"}}}"#)
    #expect(request.body(for: AnswerPayload(answers: ["Other?": "B"])) == nil)
    #expect(request.body(for: AnswerPayload(answers: ["Which?": "  "])) == nil)
    #expect(request.body(for: AnswerPayload(decision: "allow")) == nil)
}

@Test func kimiMultiSelectAnswerListsOptionIds() throws {
    let request = try #require(KimiPhoneRequest(frame: questionFrame(multi: true), now: 1, ownerPid: 1))
    #expect(request.pending.input["questions"] == json(#"[{"question":"Which?","header":"H","multiSelect":true,"options":[{"label":"A"},{"label":"B"}]}]"#))
    #expect(body(request.body(for: AnswerPayload(answers: ["Which?": "A, B"])))
            == #"/api/v1/sessions/session_1/questions/qq {"answers":{"q_0":{"kind":"multi","option_ids":["opt_0_0","opt_0_1"]}}}"#)
    #expect(body(request.body(for: AnswerPayload(answers: ["Which?": "B"])))
            == #"/api/v1/sessions/session_1/questions/qq {"answers":{"q_0":{"kind":"multi","option_ids":["opt_0_1"]}}}"#)
}
