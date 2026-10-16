import Foundation
import Testing
@testable import ClawdCore

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
