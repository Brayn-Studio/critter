import CritterKit
import Testing
@testable import CritterClient

private func request(
    _ id: String, _ session: String, _ createdAt: Int64, kind: PendingKind = .permission,
    summary: String = "", input: JSONValue = .null
) -> BridgePending {
    fixturePending(id, session, kind: kind, createdAt: createdAt, summary: summary, input: input)
}

private func command(_ text: String) -> JSONValue { .object(["command": .string(text)]) }
private func filePath(_ text: String) -> JSONValue { .object(["file_path": .string(text)]) }

/// A board of sessions "a", "b" and the like, each running, with `pending` waiting.
private func board(_ ids: [String], _ pending: [BridgePending] = []) -> SnapshotBody {
    fixtureBody(ids.map { fixtureSession($0) }, pending: pending)
}

private func card(_ id: String, in cards: [ProBoardCard]) -> ProBoardCard? {
    cards.first { $0.session.id == id }
}

@Test func aLonePermissionIsShownInFullAndAnsweredOnTheCard() throws {
    let cards = ProBoardCards.arrange(board(["a"], [request("r1", "a", 1, summary: "运行 ls", input: command("ls -la"))]))
    let ask = try #require(card("a", in: cards)?.request)
    #expect(ask.request.requestId == "r1")
    #expect(ask.what == "想 运行 ls")
    #expect(ask.detail == "ls -la")
    #expect(ask.more == 0)
    #expect(ask.isInline)
    #expect(card("a", in: cards)?.answersInline == true)
}

/// The buttons act on the oldest request, which is the one shown; with more waiting, the card opens instead.
@Test func severalRequestsShowTheOldestAndOpenTheSheet() throws {
    let cards = ProBoardCards.arrange(board(["a"], [
        request("r2", "a", 20, input: filePath("/tmp/b")),
        request("r1", "a", 10, input: filePath("/tmp/a")),
        request("r3", "a", 30),
    ]))
    let ask = try #require(card("a", in: cards)?.request)
    #expect(ask.request.requestId == "r1")
    #expect(ask.detail == "/tmp/a")
    #expect(ask.more == 2)
    #expect(!ask.isInline)
    #expect(card("a", in: cards)?.answersInline == false)
}

@Test func questionsAndPlansAlwaysOpenTheSheet() throws {
    let cards = ProBoardCards.arrange(board(["a", "b"], [
        request("q", "a", 1, kind: .question, summary: "用哪个数据库"),
        request("p", "b", 1, kind: .plan),
    ]))
    let question = try #require(card("a", in: cards)?.request)
    #expect(question.what == "问：用哪个数据库")
    #expect(question.detail == nil)
    #expect(!question.isInline)
    let plan = try #require(card("b", in: cards)?.request)
    #expect(plan.what == "计划等你批准")
    #expect(!plan.isInline)
}

@Test func noSnapshotNoCards() {
    #expect(ProBoardCards.requests(nil).isEmpty)
    #expect(ProBoardCards.arrange(nil).isEmpty)
}

@Test func cardsAlternateBetweenTheColumns() {
    let cards = ProBoardCards.arrange(board(["a", "b", "c", "d", "e"]))
    #expect(cards.filter { $0.column == .left }.map(\.session.id) == ["a", "c", "e"])
    #expect(cards.filter { $0.column == .right }.map(\.session.id) == ["b", "d"])
    #expect(cards.allSatisfy { $0.rows == 1 && $0.request == nil })
}

/// A card with a request is two rows tall and always heads the left column; the others fill the shorter column.
@Test func requestCardsStackOnTheLeftAndTakeTwoRows() {
    let body = fixtureBody(
        [
            fixtureSession("w1", state: .waiting), fixtureSession("a"), fixtureSession("w2", state: .waiting),
            fixtureSession("b"), fixtureSession("c"), fixtureSession("d"), fixtureSession("e"),
        ],
        pending: [request("r1", "w1", 1), request("r2", "w2", 2)]
    )
    let cards = ProBoardCards.arrange(body)
    #expect(cards.filter { $0.column == .left }.map(\.session.id) == ["w1", "w2", "e"])
    #expect(cards.filter { $0.column == .right }.map(\.session.id) == ["a", "b", "c", "d"])
    #expect(cards.filter { $0.request != nil }.allSatisfy { $0.rows == 2 })
    #expect(cards.filter { $0.request == nil }.allSatisfy { $0.rows == 1 })
}

/// A Codex session the phone cannot answer for is shown without a request: its card has nothing to press.
@Test func aSessionThatCannotAnswerHasNoRequestOnItsCard() {
    var codex = fixtureSession("c1", state: .waiting)
    codex.source = .codex
    codex.capabilities = BridgeCapabilities(canAnswer: false)
    let body = fixtureBody([codex, fixtureSession("a")], pending: [request("r1", "c1", 1), request("r2", "a", 2)])
    let cards = ProBoardCards.arrange(body)
    #expect(card("c1", in: cards)?.request == nil)
    #expect(card("a", in: cards)?.request?.request.requestId == "r2")
}

/// Without a summary the tool's name says what is wanted; without either, the card still says something.
@Test func aRequestWithoutASummaryNamesItsToolOrJustAnAction() throws {
    let cards = ProBoardCards.arrange(board(["a", "b"], [
        request("r1", "a", 1),
        fixturePending("r2", "b", toolName: " ", summary: " "),
    ]))
    #expect(try #require(card("a", in: cards)?.request).what == "想 Bash")
    #expect(try #require(card("b", in: cards)?.request).what == "想执行一个操作")
}
