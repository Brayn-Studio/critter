import Foundation
import Testing
@testable import CritterCore

@Test func interruptDetected() {
    let line = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"interruptedMessageId":"msg_1"}"#
    #expect(TranscriptTail.isInterrupted(tail: Data(("{\"type\":\"assistant\"}\n" + line + "\n").utf8)))
    #expect(!TranscriptTail.isInterrupted(tail: Data((line + "\n{\"type\":\"assistant\"}\n").utf8)))
    #expect(!TranscriptTail.isInterrupted(tail: Data("half a li".utf8)))
}

@Test func interruptDetectedViaMessageTextAlone() {
    // No `interruptedMessageId` key at all -- detection must still work via the message text.
    let line = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user] extra context"}]}}"#
    #expect(TranscriptTail.isInterrupted(tail: Data((line + "\n").utf8)))
}

@Test func nonUserTypeIsNotInterrupted() {
    let line = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"something else"}]}}"#
    #expect(!TranscriptTail.isInterrupted(tail: Data((line + "\n").utf8)))
}

@Test func emptyTailIsNotInterrupted() {
    #expect(!TranscriptTail.isInterrupted(tail: Data()))
}

@Test func trailingBlankLinesAreSkippedToFindLastRealLine() {
    let line = #"{"type":"user","interruptedMessageId":"m1"}"#
    #expect(TranscriptTail.isInterrupted(tail: Data((line + "\n\n").utf8)))
}

private func record(state: PetState, lastEvent: String, eventTime: Int64) -> SessionRecord {
    SessionRecord(
        schema: 1, sessionId: "s", cwd: "/x", transcriptPath: "/x/t.jsonl", state: state, detail: nil,
        lastEvent: lastEvent, eventTime: eventTime, createdAt: 0, claudePid: nil, claudeStartTime: nil
    )
}

@Test func interruptOnlyAppliesToBusySessions() {
    #expect(TranscriptTail.interruptApplies(to: record(state: .running, lastEvent: "PreToolUse", eventTime: 100), transcriptModifiedAt: 200))
    #expect(TranscriptTail.interruptApplies(to: record(state: .waiting, lastEvent: "PermissionRequest", eventTime: 100), transcriptModifiedAt: 200))
    #expect(!TranscriptTail.interruptApplies(to: record(state: .done, lastEvent: "Stop", eventTime: 100), transcriptModifiedAt: 200))
    #expect(!TranscriptTail.interruptApplies(to: record(state: .idle, lastEvent: "Interrupted", eventTime: 100), transcriptModifiedAt: 200))
}

@Test func staleInterruptLineDoesNotUndoANewPrompt() {
    // The previous turn ended with an interrupt line; the user then submitted a new prompt
    // (hook fired at t=500) before Claude appended that prompt to the transcript (last
    // modified at t=400). That old interrupt line must not flip the new turn to idle.
    #expect(!TranscriptTail.interruptApplies(to: record(state: .running, lastEvent: "UserPromptSubmit", eventTime: 500), transcriptModifiedAt: 400))
    // Esc pressed after the prompt was submitted: legit.
    #expect(TranscriptTail.interruptApplies(to: record(state: .running, lastEvent: "UserPromptSubmit", eventTime: 500), transcriptModifiedAt: 900))
    // A tool hook (e.g. PostToolUseFailure for the interrupted tool) may land after the
    // interrupt line; the interrupt still applies.
    #expect(TranscriptTail.interruptApplies(to: record(state: .running, lastEvent: "PostToolUseFailure", eventTime: 500), transcriptModifiedAt: 400))
    // Unknown modification time: be conservative only for a fresh prompt.
    #expect(!TranscriptTail.interruptApplies(to: record(state: .running, lastEvent: "UserPromptSubmit", eventTime: 500), transcriptModifiedAt: nil))
    #expect(TranscriptTail.interruptApplies(to: record(state: .running, lastEvent: "PreToolUse", eventTime: 500), transcriptModifiedAt: nil))
}

@Test func tailStartingInsideAMultiByteCharacterStillDetectsTheInterrupt() {
    // "中" is E4 B8 AD; a raw 16 KB cut can leave just its last two bytes at the start.
    let line = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"interruptedMessageId":"msg_x"}"#
    var tail = Data([0xB8, 0xAD])
    tail.append(Data(("中文内容\n" + line + "\n").utf8))
    #expect(String(data: tail, encoding: .utf8) == nil) // genuinely invalid UTF-8
    #expect(TranscriptTail.isInterrupted(tail: tail))
}

// MARK: - latestProgress

private let prompt = #"{"type":"user","message":{"role":"user","content":"跑一下测试"}}"#
private func say(_ text: String) -> String {
    #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
}
private let toolUse = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#
private let toolResult = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#
private func tail(_ lines: String...) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

@Test func progressIsTheTurnsLatestAssistantText() {
    let data = tail(say("上一轮的回答"), prompt, say("先跑测试。"), toolUse, toolResult, say("  测试通过，接着构建。\\n"), toolUse)
    #expect(TranscriptTail.latestProgress(tail: data) == "测试通过，接着构建。")
}

@Test func progressIsNilBeforeTheTurnSaysAnything() {
    #expect(TranscriptTail.latestProgress(tail: tail(say("上一轮的回答"), prompt, toolUse)) == nil)
    let interrupted = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
    #expect(TranscriptTail.latestProgress(tail: tail(say("被打断的话"), interrupted)) == nil)
}

@Test func progressLooksPastToolResultsMetaLinesAndSidechains() {
    let meta = #"{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"skill body"}]}}"#
    let sidechain = #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"子代理的话"}]}}"#
    let apiError = #"{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"API Error"}]}}"#
    let thinking = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"内部推理"}]}}"#
    let data = tail(prompt, say("在读代码。"), toolUse, toolResult, meta, sidechain, apiError, thinking, #"{"type":"attachment"}"#)
    #expect(TranscriptTail.latestProgress(tail: data) == "在读代码。")
}

@Test func progressIgnoresAPartialLastLine() {
    let data = Data((prompt + "\n" + say("完整的一句。") + "\n" + #"{"type":"assistant","message":{"content":[{"type":"text","text":"半"#).utf8)
    #expect(TranscriptTail.latestProgress(tail: data) == "完整的一句。")
}

@Test func progressKeepsTheLastTextBlockOfAMessage() {
    let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"第一段"},{"type":"tool_use","id":"t","name":"Read","input":{}},{"type":"text","text":"第二段"}]}}"#
    #expect(TranscriptTail.latestProgress(tail: tail(prompt, line)) == "第二段")
}

@Test func progressUpdateRefreshesARunningBubble() {
    var running = record(state: .running, lastEvent: "PreToolUse", eventTime: 100)
    running.detail = "Bash: make app"
    let next = TranscriptTail.progressUpdate(record: running, progress: "开始构建。")
    #expect(next?.detail == "开始构建。")
    #expect(next?.progress == "开始构建。")
    #expect(next?.lastEvent == "PreToolUse")
    #expect(next?.eventTime == 100)
    // Already showing it, or nothing found: nothing to write.
    #expect(TranscriptTail.progressUpdate(record: next!, progress: "开始构建。") == nil)
    #expect(TranscriptTail.progressUpdate(record: running, progress: nil) == nil)
}

@Test func progressUpdateLeavesOtherStatesAndFreshPromptsAlone() {
    for state in [PetState.waiting, .done, .idle, .error] {
        #expect(TranscriptTail.progressUpdate(record: record(state: state, lastEvent: "PreToolUse", eventTime: 1), progress: "话") == nil)
    }
    // Before the new prompt reaches the transcript, its tail still ends in the last turn's answer.
    #expect(TranscriptTail.progressUpdate(record: record(state: .running, lastEvent: "UserPromptSubmit", eventTime: 1), progress: "上一轮的回答") == nil)
}

@Test func progressReadsThinkingOnlyWhenShownAsUpdates() {
    // Claude Code's "updates" thinking display prints these summaries in the terminal as the
    // turn's progress lines; any other thinking stays internal.
    let update = #"{"type":"assistant","thinkingDisplay":"updates","message":{"role":"assistant","content":[{"type":"thinking","thinking":"","signature":"s"},{"type":"thinking","thinking":"测试通过，开始安装。","signature":"s"}]}}"#
    let hidden = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"内部推理","signature":"s"}]}}"#
    #expect(TranscriptTail.latestProgress(tail: tail(prompt, say("先跑测试。"), update, toolUse)) == "测试通过，开始安装。")
    #expect(TranscriptTail.latestProgress(tail: tail(prompt, say("先跑测试。"), hidden, toolUse)) == "先跑测试。")
}
