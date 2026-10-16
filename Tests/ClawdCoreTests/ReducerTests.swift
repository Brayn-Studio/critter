import Foundation
import Testing
@testable import ClawdCore

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
    #expect(r3.detail == "做完了：全部测试通过。")
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
