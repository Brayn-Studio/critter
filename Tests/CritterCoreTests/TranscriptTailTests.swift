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
