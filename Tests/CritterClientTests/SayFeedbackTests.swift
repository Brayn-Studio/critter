import CoreGraphics
import CritterKit
import Testing
@testable import CritterClient

private func result(_ ok: Bool, _ reason: ResultReason? = nil, message: String? = nil) -> CommandResult {
    CommandResult(ok: ok, reason: reason, message: message)
}

@Test func okSaysSent() {
    #expect(SayFeedback.text(for: result(true), isInterrupt: false) == "已发送")
}

@Test func unavailableExplainsWhy() {
    #expect(
        SayFeedback.text(for: result(false, .unavailable), isInterrupt: false)
            == "这个会话收不到消息（可能是启动得太早，重启会话后可用）")
}

@Test func failedShowsTheReason() {
    #expect(SayFeedback.text(for: result(false, .failed, message: "socket 连不上"), isInterrupt: false) == "socket 连不上")
}

@Test func failedWithoutAReasonStillSaysSo() {
    #expect(SayFeedback.text(for: result(false, .failed), isInterrupt: false) == "发送失败")
    #expect(SayFeedback.text(for: result(false, .failed, message: "  "), isInterrupt: false) == "发送失败")
}

@Test func unavailableKeepsTheActualBridgeExplanation() {
    #expect(
        SayFeedback.text(for: result(false, .unavailable, message: "当前 Codex 会话未连接"), isInterrupt: false, codex: true)
            == "当前 Codex 会话未连接")
}

@Test func codexUnavailableDoesNotSuggestClaudeSessionRestart() {
    #expect(
        SayFeedback.text(for: result(false, .unavailable), isInterrupt: false, codex: true)
            == "尚未连接 Codex 控制通道，请在电脑上继续操作")
}

@Test func interruptAcknowledgesTheRequestAndPreservesFailures() {
    func text(_ r: CommandResult) -> String { SayFeedback.text(for: r, isInterrupt: true) }
    #expect(text(result(true)) == "已请求停止当前回合")
    #expect(text(result(true, message: "电脑已接受停止请求")) == "电脑已接受停止请求")
    #expect(text(result(false, .unavailable)) == "当前会话无法停止，请在电脑上处理")
    // The phone's own failure (no reply at all) has no reason, only its words.
    #expect(text(.failed("没有收到电脑的回复")) == "没有收到电脑的回复")
    #expect(text(result(false, .failed)) == "停止请求未发送成功")
}

@Test func whatWasTypedDuringTheSendStays() {
    // Nothing typed meanwhile: the field is emptied.
    #expect(SayFeedback.afterSent(current: "hello", sent: "hello") == "")
    // More typed after the sent words while the send was on its way: only the sent words go.
    #expect(SayFeedback.afterSent(current: "hello 还有一件事", sent: "hello") == "还有一件事")
    // The sent words were edited meanwhile: the field is the user's new draft and is left alone.
    #expect(SayFeedback.afterSent(current: "hullo", sent: "hello") == "hullo")
}

@Test func letterArcsAndLands() {
    let path = LetterFlight.path(from: CGPoint(x: 300, y: 300), to: CGPoint(x: 150, y: 60), steps: 7)
    #expect(path.count == 7)
    #expect(path.last == CGPoint(x: 150, y: 60))
    for p in path {
        #expect(p.x.truncatingRemainder(dividingBy: 3) == 0 && p.y.truncatingRemainder(dividingBy: 3) == 0, "(\(p.x), \(p.y)) is off the 3-unit grid")
    }
    // Halfway along (the 4th of 7 steps) the letter is about 60 above the straight line.
    let straightY: CGFloat = 300 + (60 - 300) * 4 / 7
    #expect(abs(60 - (straightY - path[3].y)) <= 3)
}

/// The "发一句" field holds 4000 UTF-16 units at most: what does not fit is left out, never half a character, and the
/// sheet says so until the text is shorter than the limit again.
@Test func theSayFieldClipsAt4000Units() {
    let short = SayFeedback.fit("你好", wasClipped: true)
    #expect(short.text == "你好")
    #expect(!short.clipped)
    let full = String(repeating: "a", count: 4000)
    let atLimit = SayFeedback.fit(full, wasClipped: true)
    #expect(atLimit.text == full)
    #expect(atLimit.clipped)
    #expect(!SayFeedback.fit(full, wasClipped: false).clipped)
    let over = SayFeedback.fit(full + "bc", wasClipped: false)
    #expect(over.text == full)
    #expect(over.clipped)
    // An emoji is two units: one that would end past the limit is left out whole.
    let almost = String(repeating: "a", count: 3999)
    let emoji = SayFeedback.fit(almost + "😀", wasClipped: false)
    #expect(emoji.text == almost)
    #expect(emoji.clipped)
    #expect(SayFeedback.fit(String(repeating: "a", count: 3998) + "😀", wasClipped: true).text.utf16.count == 4000)
}
