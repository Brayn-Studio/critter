import Foundation
import Testing
@testable import CritterCore

private func record(
    sessionId: String = "s",
    cwd: String = "/x",
    state: PetState,
    detail: String? = nil,
    lastEvent: String = "SessionStart",
    eventTime: Int64 = 0,
    createdAt: Int64 = 0,
    claudePid: Int32? = nil,
    claudeStartTime: Int64? = nil,
    transcriptPath: String? = nil
) -> SessionRecord {
    SessionRecord(
        schema: 1, sessionId: sessionId, cwd: cwd, transcriptPath: transcriptPath, state: state,
        detail: detail, lastEvent: lastEvent, eventTime: eventTime, createdAt: createdAt,
        claudePid: claudePid, claudeStartTime: claudeStartTime
    )
}

private func input(_ json: String) -> HookInput {
    try! JSONDecoder().decode(HookInput.self, from: Data(json.utf8))
}

@Test func petPromptIsIgnored() {
    let prev = record(state: .idle)
    #expect(StateReducer.reduce(previous: prev, input: input(#"{"session_id":"s","cwd":"/x","hook_event_name":"UserPromptSubmit","prompt":"/pet"}"#), now: 10, pid: 1, pidStartTime: 1) == .ignore)
    #expect(StateReducer.reduce(previous: prev, input: input(#"{"session_id":"s","cwd":"/x","hook_event_name":"UserPromptSubmit","prompt":"  /pet  "}"#), now: 10, pid: 1, pidStartTime: 1) == .ignore)
    // "/petshop" 不是 /pet
    guard case .write(let r) = StateReducer.reduce(previous: prev, input: input(#"{"session_id":"s","cwd":"/x","hook_event_name":"UserPromptSubmit","prompt":"/petshop"}"#), now: 10, pid: 1, pidStartTime: 1) else { Issue.record(); return }
    #expect(r.state == .running)
}

@Test func permissionThenToolThenStop() {
    guard case .write(let r1) = StateReducer.reduce(
        previous: nil,
        input: input(#"{"session_id":"s","cwd":"/x","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test"}}"#),
        now: 1, pid: 100, pidStartTime: 1000
    ) else { Issue.record("expected write"); return }
    #expect(r1.state == .waiting)
    #expect(r1.detail == "需要你确认：Bash(npm test)")

    guard case .write(let r2) = StateReducer.reduce(
        previous: r1,
        input: input(#"{"session_id":"s","cwd":"/x","hook_event_name":"PostToolUse","tool_name":"Bash"}"#),
        now: 2, pid: 100, pidStartTime: 1000
    ) else { Issue.record("expected write"); return }
    #expect(r2.state == .running)
    #expect(r2.detail == "思考中…")

    guard case .write(let r3) = StateReducer.reduce(
        previous: r2,
        input: input(#"{"session_id":"s","cwd":"/x","hook_event_name":"Stop","last_assistant_message":"全部测试通过。接下来…"}"#),
        now: 3, pid: 100, pidStartTime: 1000
    ) else { Issue.record("expected write"); return }
    #expect(r3.state == .done)
    #expect(r3.detail == "全部测试通过。")
}

@Test func askUserQuestionIsWaiting() {
    guard case .write(let r) = StateReducer.reduce(
        previous: nil,
        input: input(#"{"session_id":"s","cwd":"/x","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}"#),
        now: 1, pid: nil, pidStartTime: nil
    ) else { Issue.record("expected write"); return }
    #expect(r.state == .waiting)
    #expect(r.detail == "Claude 在问你问题")
}

@Test func stopFailureIsError() {
    guard case .write(let r) = StateReducer.reduce(
        previous: nil,
        input: input(#"{"session_id":"s","cwd":"/x","hook_event_name":"StopFailure","error_type":"rate_limit"}"#),
        now: 1, pid: nil, pidStartTime: nil
    ) else { Issue.record("expected write"); return }
    #expect(r.state == .error)
    #expect(r.detail == "出错了：rate_limit")
}

@Test func sessionEndDeletes() {
    let result = StateReducer.reduce(
        previous: record(state: .running),
        input: input(#"{"session_id":"s","cwd":"/x","hook_event_name":"SessionEnd","reason":"exit"}"#),
        now: 1, pid: nil, pidStartTime: nil
    )
    #expect(result == .delete)
}

@Test func compactKeepsState() {
    let prev = record(state: .running)
    let result = StateReducer.reduce(
        previous: prev,
        input: input(#"{"session_id":"s","cwd":"/x","hook_event_name":"SessionStart","source":"compact"}"#),
        now: 1, pid: nil, pidStartTime: nil
    )
    #expect(result == .ignore)
}

@Test func idlePromptNotificationIgnored() {
    let result = StateReducer.reduce(
        previous: nil,
        input: input(#"{"session_id":"s","cwd":"/x","hook_event_name":"Notification","notification_type":"idle_prompt","message":"hi"}"#),
        now: 1, pid: nil, pidStartTime: nil
    )
    #expect(result == .ignore)
}

@Test func createdAtPreservedAndPidCarriedOver() {
    let prev = record(state: .idle, createdAt: 3, claudePid: 9, claudeStartTime: 100)
    guard case .write(let r) = StateReducer.reduce(
        previous: prev,
        input: input(#"{"session_id":"s","cwd":"/x","hook_event_name":"UserPromptSubmit","prompt":"hello"}"#),
        now: 50, pid: nil, pidStartTime: nil
    ) else { Issue.record("expected write"); return }
    #expect(r.createdAt == 3)
    #expect(r.claudePid == 9)
    #expect(r.claudeStartTime == 100)
    #expect(r.eventTime == 50)
}

/// F5: the session's entrypoint is kept in its state file, so an SDK/`-p` session can be
/// recognized even when Claude's registry doesn't (yet) list it.
@Test func reducerRecordsTheEntrypointAndKeepsIt() {
    guard case .write(let first) = StateReducer.reduce(
        previous: nil, input: input(#"{"session_id":"s","cwd":"/x","hook_event_name":"SessionStart","source":"startup"}"#),
        now: 10, pid: 1, pidStartTime: 1, entrypoint: "sdk-cli"
    ) else { Issue.record(); return }
    #expect(first.entrypoint == "sdk-cli")
    #expect(first.schema == 1)

    guard case .write(let next) = StateReducer.reduce(
        previous: first, input: input(#"{"session_id":"s","cwd":"/x","hook_event_name":"UserPromptSubmit","prompt":"hi"}"#),
        now: 20, pid: 1, pidStartTime: 1, entrypoint: nil
    ) else { Issue.record(); return }
    #expect(next.entrypoint == "sdk-cli")
}

private func activity(_ json: String) -> String?? {
    guard case .write(let r) = StateReducer.reduce(previous: nil, input: input(json), now: 10, pid: 1, pidStartTime: 1) else { return .none }
    return .some(r.activity)
}

@Test func promptSubmitRecordsThink() {
    #expect(activity(#"{"session_id":"s","cwd":"/x","hook_event_name":"UserPromptSubmit","prompt":"hi"}"#) == .some("think"))
}

@Test func preToolUseRecordsToolActivity() {
    for (tool, want) in [("Edit", "laptop"), ("Read", "read"), ("Bash", "bash"), ("Task", "juggle")] {
        let json = #"{"session_id":"s","cwd":"/x","hook_event_name":"PreToolUse","tool_name":"\#(tool)","tool_input":{}}"#
        #expect(activity(json) == .some(want))
    }
}

@Test func postToolUseBackToThink() {
    for event in ["PostToolUse", "PostToolUseFailure", "PermissionDenied"] {
        let json = #"{"session_id":"s","cwd":"/x","hook_event_name":"\#(event)","tool_name":"Edit"}"#
        #expect(activity(json) == .some("think"))
    }
}

@Test func stopClearsActivity() {
    let prev = SessionRecord(schema: 1, sessionId: "s", cwd: "/x", transcriptPath: nil, state: .running, detail: nil,
                             lastEvent: "PreToolUse", eventTime: 1, createdAt: 1, claudePid: nil, claudeStartTime: nil,
                             activity: "bash")
    guard case .write(let r) = StateReducer.reduce(previous: prev, input: input(#"{"session_id":"s","cwd":"/x","hook_event_name":"Stop"}"#), now: 10, pid: 1, pidStartTime: 1) else { Issue.record(); return }
    #expect(r.activity == nil)
}

@Test func askUserQuestionHasNoActivity() {
    guard case .write(let r) = StateReducer.reduce(previous: nil, input: input(#"{"session_id":"s","cwd":"/x","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{}}"#), now: 10, pid: 1, pidStartTime: 1) else { Issue.record(); return }
    #expect(r.state == .waiting)
    #expect(r.activity == nil)
}

// MARK: - progress (the turn's latest assistant text)

private func reduce(_ previous: SessionRecord?, _ json: String, progress: String? = nil) -> SessionRecord? {
    guard case .write(let r) = StateReducer.reduce(previous: previous, input: input(json), now: 10, pid: 1, pidStartTime: 1, progress: progress) else { return nil }
    return r
}

@Test func progressReplacesThinkingAndToolSummaries() {
    let pre = reduce(nil, #"{"session_id":"s","cwd":"/x","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"swift test"}}"#, progress: "先跑一遍测试。")
    #expect(pre?.detail == "先跑一遍测试。")
    #expect(pre?.progress == "先跑一遍测试。")
    #expect(pre?.activity == "bash")

    // Nothing new said since: the last progress carries on through the thinking gap.
    let post = reduce(pre, #"{"session_id":"s","cwd":"/x","hook_event_name":"PostToolUse","tool_name":"Bash"}"#)
    #expect(post?.detail == "先跑一遍测试。")
    #expect(post?.activity == "think")

    let next = reduce(post, #"{"session_id":"s","cwd":"/x","hook_event_name":"PostToolUse","tool_name":"Bash"}"#, progress: "测试通过，接着构建。")
    #expect(next?.detail == "测试通过，接着构建。")
}

@Test func waitingStillOutranksProgress() {
    let prev = reduce(nil, #"{"session_id":"s","cwd":"/x","hook_event_name":"PostToolUse","tool_name":"Bash"}"#, progress: "准备提交。")
    let asking = reduce(prev, #"{"session_id":"s","cwd":"/x","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"git push"}}"#)
    #expect(asking?.detail == "需要你确认：Bash(git push)")
    #expect(asking?.progress == "准备提交。")
    let question = reduce(prev, #"{"session_id":"s","cwd":"/x","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{}}"#, progress: "问一下你。")
    #expect(question?.detail == "Claude 在问你问题")
}

@Test func newPromptClearsProgress() {
    let prev = reduce(nil, #"{"session_id":"s","cwd":"/x","hook_event_name":"PostToolUse","tool_name":"Bash"}"#, progress: "上一轮的话。")
    let fresh = reduce(prev, #"{"session_id":"s","cwd":"/x","hook_event_name":"UserPromptSubmit","prompt":"继续"}"#)
    #expect(fresh?.progress == nil)
    #expect(fresh?.detail == "思考中…")
    let tool = reduce(fresh, #"{"session_id":"s","cwd":"/x","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x/a.swift"}}"#)
    #expect(tool?.detail == "读取 a.swift")
}
