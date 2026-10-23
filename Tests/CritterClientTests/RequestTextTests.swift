import CritterClient
import CritterKit
import Foundation
import Testing

/// `AnswerInputTest.kt`, `CodexApprovalUiTest.kt` and `PresentationTest.requestTitleNamesTheSessionAndWhatItWants`.
struct RequestTextTests {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func session(name: String = "proj") -> BridgeSession {
        var s = fixtureSession("s1", state: .waiting)
        s.name = name
        return s
    }

    // MARK: - What a request asks

    @Test func permissionBodyPrefersCommandThenFilePathThenUrl() throws {
        #expect(RequestText.permissionBody(try json(#"{"command":"ls","file_path":"/a","url":"u"}"#)) == "ls")
        #expect(RequestText.permissionBody(try json(#"{"file_path":"/a","url":"u"}"#)) == "/a")
        #expect(RequestText.permissionBody(try json(#"{"url":"u"}"#)) == "u")
        #expect(RequestText.permissionBody(try json(#"{"other":"x"}"#)) == nil)
        #expect(RequestText.permissionBody(.null) == nil)
    }

    @Test func permissionBodySkipsBlankAndNonStringValues() throws {
        #expect(RequestText.permissionBody(try json(#"{"command":"  ","file_path":"/a"}"#)) == "/a")
        #expect(RequestText.permissionBody(try json(#"{"command":3,"url":"u"}"#)) == "u")
    }

    @Test func questionsAreReadWithOptionsAndMultiSelect() throws {
        let q = RequestText.questions(try json("""
            {"questions":[{"header":"DB","question":"Which database?","multiSelect":false,
            "options":[{"label":"PostgreSQL","description":"relational"},{"label":"SQLite"}]},
            {"question":"Which extras?","multiSelect":true,"options":[{"label":"A"}]}]}
            """))
        #expect(q.count == 2)
        #expect(q[0].header == "DB")
        #expect(q[0].text == "Which database?")
        #expect(q[0].options.map(\.label) == ["PostgreSQL", "SQLite"])
        #expect(q[0].options[0].description == "relational")
        #expect(q[0].options[1].description == nil)
        #expect(!q[0].multiSelect)
        #expect(q[1].header == nil)
        #expect(q[1].multiSelect)
        #expect(!RequestText.submitsOnPick(q))
        #expect(RequestText.submitsOnPick(Array(q.prefix(1))))
        #expect(!RequestText.submitsOnPick(Array(q.dropFirst())))
    }

    @Test func questionsSkipWhatIsNotAQuestionOrAnOption() throws {
        let q = RequestText.questions(try json("""
            {"questions":["x",{"header":"no question text"},
            {"question":"Q","options":["x",{"description":"no label"},{"label":"A"}]}]}
            """))
        #expect(q.count == 1)
        #expect(q[0].options.map(\.label) == ["A"])
        #expect(RequestText.questions(.null).isEmpty)
        #expect(RequestText.questions(try json(#"{"questions":"nope"}"#)).isEmpty)
    }

    @Test func planTextComesFromThePlanKey() throws {
        #expect(RequestText.planText(try json(##"{"plan":"# Do it"}"##)) == "# Do it")
        #expect(RequestText.planText(.null) == "")
        #expect(RequestText.planText(try json(#"{"plan":4}"#)) == "")
    }

    @Test func codexApprovalsDoNotOfferAReasonThatCannotBeDelivered() throws {
        #expect(!RequestText.acceptsDenyMessage(try json(#"{"command":"swift test","acceptsDenyMessage":false}"#)))
    }

    @Test func existingClaudePermissionsKeepTheOptionalReason() throws {
        #expect(RequestText.acceptsDenyMessage(.null))
        #expect(RequestText.acceptsDenyMessage(try json(#"{"command":"swift test"}"#)))
        #expect(RequestText.acceptsDenyMessage(try json(#"{"acceptsDenyMessage":true}"#)))
        #expect(RequestText.acceptsDenyMessage(try json(#"{"acceptsDenyMessage":"no"}"#)))
    }

    // MARK: - The title

    @Test func requestTitleNamesTheSessionAndWhatItWants() {
        #expect(RequestText.title(fixturePending("r1", "s1", summary: "运行 npm test"), session: session()) == "proj 想 运行 npm test")
        #expect(RequestText.title(fixturePending("r1", "s1", kind: .plan, summary: "运行 npm test"), session: session()) == "proj 的计划等你批准")
        #expect(RequestText.title(fixturePending("r1", "s1", toolName: "", summary: ""), session: nil) == "会话 想执行一个操作")
    }

    @Test func titleCopy() {
        let critter = session(name: "critter")
        #expect(RequestText.title(fixturePending("r", "s1", summary: "swift test"), session: critter) == "critter 想 swift test")
        #expect(RequestText.title(fixturePending("r", "s1", kind: .question, summary: "Which database?"), session: critter) == "critter 问：Which database?")
        #expect(RequestText.title(fixturePending("r", "s1", kind: .plan), session: critter) == "critter 的计划等你批准")
        #expect(RequestText.title(fixturePending("r", "s1", toolName: "", summary: ""), session: critter) == "critter 想执行一个操作")
        #expect(RequestText.title(fixturePending("r", "s1", kind: .question, toolName: "", summary: ""), session: critter) == "critter 有问题要问你")
    }

    /// With no summary the tool's name says what it wants; a blank summary counts as none.
    @Test func titleFallsBackToTheToolName() {
        let critter = session(name: "critter")
        #expect(RequestText.title(fixturePending("r", "s1", toolName: "Bash", summary: ""), session: critter) == "critter 想 Bash")
        #expect(RequestText.title(fixturePending("r", "s1", toolName: "Bash", summary: "  "), session: critter) == "critter 想 Bash")
    }

    // MARK: - What came of an answer

    @Test func answerOutcomeMapsTheMacReceipt() {
        func result(_ ok: Bool, _ reason: ResultReason? = nil, _ message: String? = nil) -> AnswerOutcome {
            AnswerOutcome(CommandResult(ok: ok, reason: reason, message: message))
        }
        #expect(result(true) == .sent)
        #expect(result(false, .resolved) == .handledElsewhere)
        #expect(result(false, .failed, "socket 断了") == .failed("socket 断了"))
        #expect(result(false, .failed) == .failed("没有发送出去，再试一次"))
    }

    /// The phone's own failures ("未连接", "超时") have no reason: the card stays open with them.
    @Test func answerOutcomeKeepsThePhonesOwnFailures() {
        #expect(AnswerOutcome(.failed("未连接")) == .failed("未连接"))
        #expect(AnswerOutcome(.failed("超时")) == .failed("超时"))
        #expect(AnswerOutcome(CommandResult(ok: false, reason: .invalid, message: nil)) == .failed("没有发送出去，再试一次"))
    }

    /// Too late: the hook stopped waiting. Like "handled elsewhere" the card says so and closes; nothing to retry.
    @Test func anExpiredRequestClosesTheCardWithTheMacsWords() {
        func expired(_ message: String?) -> AnswerOutcome {
            AnswerOutcome(CommandResult(ok: false, reason: .expired, message: message))
        }
        #expect(expired(nil) == .expired("这个请求已经过期了"))
        #expect(expired(" ") == .expired("这个请求已经过期了"))
        #expect(expired("超过了等待时间") == .expired("超过了等待时间"))
    }

    @Test func aYesGetsASuccessBeatANoDoesNot() {
        #expect(successLabel(AnswerPayload(decision: "allow")) == "已允许")
        #expect(successLabel(AnswerPayload(decision: "approve")) == "已批准")
        #expect(successLabel(AnswerPayload(answers: ["Which?": "A"])) == "已提交")
        #expect(successLabel(AnswerPayload(decision: "deny", message: "不要")) == nil)
        #expect(successLabel(AnswerPayload(decision: "revise", message: "先写测试")) == nil)
    }

    // MARK: - The card

    @Test func cardStateWhenTheRequestLeavesTheSnapshot() {
        let request = fixturePending("r1", "s1")
        let before = fixtureBody([fixtureSession("s1", state: .waiting)], pending: [request])
        #expect(CardState(requestId: "r1", snapshot: before, everSeen: false) == .open(request))
        // The same card, a snapshot later: the Mac (or the terminal) answered first.
        let after = fixtureBody([fixtureSession("s1")])
        #expect(CardState(requestId: "r1", snapshot: after, everSeen: true) == .handledElsewhere)
    }

    @Test func cardStateForARequestNeverSeen() {
        let body = fixtureBody([fixtureSession("s1")], pending: [fixturePending("other", "s1")])
        #expect(CardState(requestId: "r1", snapshot: body, everSeen: false) == .unknown)
        #expect(CardState(requestId: "r1", snapshot: nil, everSeen: false) == .unknown)
    }

    /// The card shows the request the card was opened for, not whatever else the session is waiting on.
    @Test func cardStateFollowsTheRequestIdNotTheSession() {
        let second = fixturePending("r2", "s1", createdAt: 2)
        let body = fixtureBody([fixtureSession("s1", state: .waiting)], pending: [second])
        #expect(CardState(requestId: "r1", snapshot: body, everSeen: true) == .handledElsewhere)
        #expect(CardState(requestId: "r2", snapshot: body, everSeen: true) == .open(second))
    }
}
