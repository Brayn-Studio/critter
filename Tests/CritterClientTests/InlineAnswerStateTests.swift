import Testing
@testable import CritterClient

/// The line over a card's 「拒绝」「允许」 for each state.
@Test func theLineOverTheButtonsReadsTheState() {
    #expect(InlineAnswerState.idle.status == nil)
    #expect(InlineAnswerState.sending.status?.text == "正在提交…")
    #expect(InlineAnswerState.sending.status?.tone == .quiet)
    #expect(InlineAnswerState.sent("已允许").status?.text == "已允许")
    #expect(InlineAnswerState.sent("已允许").status?.tone == .success)
    // A no that went through says nothing.
    #expect(InlineAnswerState.sent(nil).status == nil)
    #expect(InlineAnswerState.closed("已在电脑上处理").status?.text == "已在电脑上处理")
    #expect(InlineAnswerState.closed("已在电脑上处理").status?.tone == .quiet)
    #expect(InlineAnswerState.failed("提交失败").status?.text == "提交失败")
    #expect(InlineAnswerState.failed("提交失败").status?.tone == .failure)
}

/// The buttons work while the phone can act, before an answer is on its way or after one failed.
@Test func theButtonsWorkOnlyBeforeAnAnswerOrAfterAFailure() {
    let all: [InlineAnswerState] = [.idle, .sending, .sent("已允许"), .sent(nil), .closed("x"), .failed("y")]
    let enabled = all.filter { $0.buttonsEnabled(.allowDeny) }
    #expect(enabled == [.idle, .failed("y")])
    for rule: InlineAnswer in [.none, .allowDenyDisabled, .open] {
        #expect(all.allSatisfy { !$0.buttonsEnabled(rule) }, "\(rule)")
    }
}
