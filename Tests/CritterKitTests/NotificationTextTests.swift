import Foundation
import Testing
@testable import CritterKit

// `PresentationTest.kt` (requestTitle, requestText, folderName) and `Alerts.kt` (waitingNoticeTitle, the result
// notification's title).

private func session(
    name: String = "proj", cwd: String = "/Users/me/proj/", branch: String? = "main", state: PetState = .waiting,
    source: SessionSource = .terminal, detail: String? = nil
) -> BridgeSession {
    BridgeSession(
        id: "s1", name: name, source: source, state: state, detail: detail, cwd: cwd, branch: branch,
        skin: "sprig", eventTime: 0, startedAt: 0, tracked: true
    )
}

private func request(
    _ kind: PendingKind, summary: String = "运行 npm test", toolName: String = "Bash", input: JSONValue = .null
) -> BridgePending {
    BridgePending(
        requestId: "r1", sessionId: "s1", kind: kind, toolName: toolName, summary: summary, input: input,
        createdAt: 0, expiresAt: nil
    )
}

private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Test func requestTitleNamesTheSessionAndWhatItWants() {
    #expect(NotificationText.title(request(.permission), session: session()) == "proj 想 运行 npm test")
    #expect(NotificationText.title(request(.plan), session: session()) == "proj 的计划等你批准")
    #expect(NotificationText.title(request(.question, summary: "用哪个数据库？"), session: session()) == "proj 问：用哪个数据库？")
    #expect(NotificationText.title(request(.question, summary: "", toolName: ""), session: session()) == "proj 有问题要问你")
    // No summary: the tool's name; no tool either: a general line. Without the session: "会话".
    #expect(NotificationText.title(request(.permission, summary: " "), session: session()) == "proj 想 Bash")
    #expect(NotificationText.title(request(.permission, summary: "", toolName: ""), session: nil) == "会话 想执行一个操作")
}

@Test func requestBodyShowsTheCommandOrThePath() throws {
    let command = request(.permission, input: try json(#"{"command":"./gradlew test"}"#))
    #expect(NotificationText.requestBody(command, session: session()) == "./gradlew test")
    let path = request(.permission, input: try json(#"{"file_path":"/tmp/a.txt"}"#))
    #expect(NotificationText.requestBody(path, session: session()) == "/tmp/a.txt")
    // A question or a plan shows the session's folder ("/Users/me/proj/" -> "proj")...
    #expect(NotificationText.requestBody(request(.question), session: session()) == "proj")
    #expect(NotificationText.requestBody(request(.plan), session: session()) == "proj")
    // ...and so does a permission without a command or path.
    #expect(NotificationText.requestBody(request(.permission), session: session()) == "proj")
    // Nothing to show without a session.
    #expect(NotificationText.requestBody(request(.permission), session: nil) == nil)
    #expect(NotificationText.requestBody(command, session: nil) == "./gradlew test")
}

@Test func permissionBodyPrefersCommandThenFilePathThenUrl() throws {
    #expect(NotificationText.permissionBody(try json(#"{"command":"ls","file_path":"/a","url":"u"}"#)) == "ls")
    #expect(NotificationText.permissionBody(try json(#"{"command":"  ","file_path":"/a"}"#)) == "/a")
    #expect(NotificationText.permissionBody(try json(#"{"url":"u"}"#)) == "u")
    #expect(NotificationText.permissionBody(try json(#"{"other":"x"}"#)) == nil)
    #expect(NotificationText.permissionBody(.null) == nil)
}

@Test func codexApprovalsAcceptNoReason() throws {
    #expect(!NotificationText.acceptsDenyMessage(try json(#"{"acceptsDenyMessage":false}"#)))
    #expect(NotificationText.acceptsDenyMessage(try json(#"{"acceptsDenyMessage":true}"#)))
    #expect(NotificationText.acceptsDenyMessage(try json(#"{"command":"ls"}"#)))
    #expect(NotificationText.acceptsDenyMessage(.null))
}

@Test func waitingNoticeSaysToGoToTheComputer() {
    #expect(NotificationText.waitingNoticeTitle(session()) == "proj 等你确认（请在电脑上处理）")
    // What it is doing, else the folder.
    #expect(NotificationText.waitingNoticeBody(session(detail: "运行 npm test")) == "运行 npm test")
    #expect(NotificationText.waitingNoticeBody(session(detail: "  ")) == "proj")
    #expect(NotificationText.waitingNoticeBody(session()) == "proj")
}

@Test func resultTitleIsTheNameAndTheState() {
    #expect(NotificationText.resultTitle(session(), state: .done) == "proj 做完了")
    #expect(NotificationText.resultTitle(session(), state: .error) == "proj 出错")
    #expect(NotificationText.resultBody(session(detail: "测试通过")) == "测试通过")
    #expect(NotificationText.resultBody(session()) == "")
}

@Test func folderNameAndPlaceAreThePhonesWords() {
    #expect(NotificationText.folderName("/Users/me/proj/") == "proj")
    #expect(NotificationText.folderName("/") == "/")
    #expect(NotificationText.place(session()) == "proj · main · 终端")
    #expect(NotificationText.place(session(branch: nil, source: .codexVSCode)) == "proj · Codex · VS Code")
    // An old snapshot's Codex arrives as `other`; its namespaced id still says what it is.
    var codex = session(source: .other)
    codex.id = "codex-thread"
    #expect(NotificationText.place(codex) == "proj · main · Codex")
    #expect(NotificationText.source(.desktop) == "桌面版")
    #expect(NotificationText.isCodex(codex))
    #expect(NotificationText.visibleSource(codex) == .codex)
}
