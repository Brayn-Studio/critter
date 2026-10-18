import Foundation
import Testing
@testable import CritterCore

@Test func usageFromLastAssistantLine() {
    let tail = """
    partial-line-cut-off"}
    {"type":"assistant","message":{"model":"claude-haiku-5-5","usage":{"input_tokens":1,"cache_read_input_tokens":2}}}
    {"type":"user","message":{"content":"hi"}}
    {"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_creation_input_tokens":200,"cache_read_input_tokens":5000,"output_tokens":99}}}

    """
    #expect(ContextUsage.lastUsage(inTranscriptTail: Data(tail.utf8)) == ContextEstimate(usedTokens: 5210, model: "claude-opus-5-5"))
}

@Test func usageIgnoresTruncatedLastLine() {
    let tail = """
    cut
    {"type":"assistant","message":{"model":"m1","usage":{"input_tokens":7}}}
    {"type":"assistant","message":{"model":"m2","usage":{"input_tokens":99
    """
    #expect(ContextUsage.lastUsage(inTranscriptTail: Data(tail.utf8)) == ContextEstimate(usedTokens: 7, model: "m1"))
}

@Test func usageNilWithoutAssistantUsage() {
    let tail = """
    cut
    {"type":"user","message":{"content":"hi"}}
    {"type":"assistant","message":{"model":"m"}}

    """
    #expect(ContextUsage.lastUsage(inTranscriptTail: Data(tail.utf8)) == nil)
    #expect(ContextUsage.lastUsage(inTranscriptTail: Data()) == nil)
}

@Test func windowSizesByModel() {
    #expect(ContextUsage.windowSize(forModel: "claude-opus-5-5") == 1_000_000)
    #expect(ContextUsage.windowSize(forModel: "claude-sonnet-4-6") == 200_000)
    #expect(ContextUsage.windowSize(forModel: "claude-sonnet-4-6[1m]") == 1_000_000)
    #expect(ContextUsage.windowSize(forModel: nil) == 200_000)
}

@Test func percentRounds() {
    #expect(ContextUsage.percent(usedTokens: 5210, windowSize: 200_000) == 2.6)
    #expect(ContextUsage.percent(usedTokens: 500_000, windowSize: 200_000) == 100)
    #expect(ContextUsage.percent(usedTokens: 1, windowSize: 0) == 0)
}
