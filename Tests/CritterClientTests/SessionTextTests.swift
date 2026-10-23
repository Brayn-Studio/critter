import CritterClient
import CritterKit
import Foundation
import Testing

/// `PresentationTest.kt` and `CodexSessionUiTest.kt`, for the functions that moved to `SessionText`.
struct SessionTextTests {
    private func session(
        source: SessionSource = .codex, id: String = "codex-thread", state: PetState = .waiting,
        capabilities: BridgeCapabilities? = nil
    ) -> BridgeSession {
        BridgeSession(
            id: id, name: "project", source: source, state: state, cwd: "/project", skin: "sprig",
            eventTime: 0, startedAt: 0, tracked: true, capabilities: capabilities
        )
    }

    private func claude() -> BridgeSession {
        session(source: .terminal, id: "claude-thread")
    }

    // MARK: - PresentationTest

    @Test func stateNamesMatchTheDesktop() {
        #expect([PetState.idle, .running, .waiting, .done, .error].map(\.label) == ["空闲", "运行中", "等你确认", "做完了", "出错"])
    }

    @Test func folderNameHandlesATrailingSlash() {
        #expect(SessionText.folderName("/Users/me/proj/") == "proj")
        #expect(SessionText.folderName("/Users/me/proj") == "proj")
        #expect(SessionText.folderName("~/CODESPACE/clawd") == "clawd")
        #expect(SessionText.folderName("proj") == "proj")
        #expect(SessionText.folderName("/") == "/")
        #expect(SessionText.folderName("") == "")
    }

    @Test func placeOrderIsFolderBranchSource() {
        var s = session(source: .terminal, id: "s1")
        s.cwd = "~/CODESPACE/clawd"
        s.branch = "main"
        #expect(SessionText.place(s) == "clawd · main · 终端")
    }

    @Test func placeLeavesOutAMissingOrBlankBranch() {
        var s = session(source: .vscode, id: "s1")
        s.cwd = "/Users/me/proj/"
        #expect(SessionText.place(s) == "proj · VS Code")
        s.branch = "  "
        #expect(SessionText.place(s) == "proj · VS Code")
    }

    @Test func placeNamesCodexForAnOldSnapshotsOther() {
        #expect(SessionText.place(session(source: .other)) == "project · Codex")
        #expect(SessionText.place(session(source: .other, id: "claude-thread")) == "project · 其它")
    }

    @Test func sourceNamesAreAndroidsNotTheDesktops() {
        #expect(SessionText.source(.terminal) == "终端")
        #expect(SessionText.source(.vscode) == "VS Code")
        #expect(SessionText.source(.desktop) == "桌面版")
        #expect(SessionText.source(.other) == "其它")
        #expect(SessionText.source(.codex) == "Codex")
        #expect(SessionText.source(.codexTerminal) == "Codex · 终端")
        #expect(SessionText.source(.codexVSCode) == "Codex · VS Code")
        #expect(SessionText.source(.codexDesktop) == "Codex · Desktop")
    }

    @Test func estimatedContextGetsAnApproxSign() {
        #expect(SessionText.contextPercent(BridgeContext(usedPercent: 41.6, windowSize: 200_000, estimated: true)) == "≈42%")
        #expect(SessionText.contextPercent(BridgeContext(usedPercent: 41.6, windowSize: 200_000, estimated: false)) == "42%")
    }

    @Test func contextPercentSurvivesAbsurdNumbers() {
        #expect(SessionText.contextPercent(BridgeContext(usedPercent: 1e30, windowSize: 1, estimated: false)) == "2147483647%")
        #expect(SessionText.contextPercent(BridgeContext(usedPercent: 0.4, windowSize: 1, estimated: false)) == "0%")
    }

    @Test func agoText() {
        func at(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
        #expect(SessionText.ago(at(1_000), now: at(30_000)) == "刚刚")
        #expect(SessionText.ago(at(0), now: at(5 * 60_000 + 1)) == "5 分钟前")
        #expect(SessionText.ago(at(0), now: at(2 * 3_600_000)) == "2 小时前")
        #expect(SessionText.ago(at(0), now: at(59 * 60_000 + 59_000)) == "59 分钟前")
        #expect(SessionText.ago(at(0), now: at(60 * 60_000)) == "1 小时前")
        // A clock that is behind the Mac's is never "-3 minutes ago".
        #expect(SessionText.ago(at(10 * 60_000), now: at(0)) == "刚刚")
    }

    @Test func connectionTexts() {
        #expect(SessionText.conn(.idle) == "未连接")
        #expect(SessionText.conn(.connecting) == "连接中…")
        #expect(SessionText.conn(.awaitingApproval) == "请在 Mac 上点允许")
        #expect(SessionText.conn(.connected(macName: "Mac")) == "已连接")
        #expect(SessionText.conn(.offline(retryIn: .seconds(2), since: Date(timeIntervalSince1970: 0))) == "未连接，正在重试")
        #expect(SessionText.conn(.needsRepair(reason: "配对被拒绝")) == "配对被拒绝")
    }

    @Test func doingIsTheDetailThenTheActivityThenTheStateName() {
        var s = session(source: .terminal, id: "s1", state: .running)
        #expect(SessionText.doing(s) == "运行中")
        s.activity = "编辑 App.swift"
        #expect(SessionText.doing(s) == "编辑 App.swift")
        s.detail = "运行 swift test"
        #expect(SessionText.doing(s) == "运行 swift test")
        s.detail = "  "
        #expect(SessionText.doing(s) == "编辑 App.swift")
        s.activity = ""
        #expect(SessionText.doing(s) == "运行中")
    }

    // MARK: - CodexSessionUiTest

    @Test func codexSourcesAndOldUnknownSnapshotsAreRecognized() {
        for source in [SessionSource.codex, .codexTerminal, .codexVSCode, .codexDesktop] {
            #expect(SessionText.isCodex(session(source: source)))
        }
        #expect(SessionText.isCodex(session(source: .other)))
        #expect(SessionText.visibleSource(session(source: .other)) == .codex)
        #expect(!SessionText.isCodex(session(source: .other, id: "claude-thread")))
        #expect(SessionText.visibleSource(session(source: .other, id: "claude-thread")) == .other)
        #expect(SessionText.visibleSource(session(source: .codexTerminal)) == .codexTerminal)
        #expect(SessionText.source(.codex) == "Codex")
        #expect(SessionText.source(.terminal) == "终端")
    }

    @Test func codexMessagesRequireAnExplicitLiveOwnerCapability() {
        #expect(!SessionText.supportsMessages(session()))
        #expect(!SessionText.supportsMessages(session(source: .other)))
        #expect(SessionText.supportsMessages(session(capabilities: BridgeCapabilities(canSay: true))))
        #expect(!SessionText.supportsMessages(session(capabilities: BridgeCapabilities(canAnswer: true))))
        #expect(SessionText.supportsMessages(claude()))
    }

    @Test func stopAndAnswersUseTheirOwnCapabilities() {
        #expect(!SessionText.supportsAnswers(session()))
        let connected = session(capabilities: BridgeCapabilities(canAnswer: true, canInterrupt: true))
        #expect(SessionText.supportsAnswers(connected))
        #expect(SessionText.canStopTurn(connected, online: true))
        #expect(!SessionText.canStopTurn(connected, online: false))
        #expect(!SessionText.canStopTurn(session(capabilities: BridgeCapabilities(canSay: true)), online: true))
        #expect(SessionText.supportsAnswers(claude()))
        // Without capabilities a Claude session cannot be stopped from the phone.
        #expect(!SessionText.canStopTurn(claude(), online: true))
    }

    @Test func composerExplainsTheActualProviderRoute() {
        #expect(SessionText.messageHint(session(capabilities: BridgeCapabilities(canSay: true))) == "发送到当前 Codex 会话")
        #expect(SessionText.messageHint(session(capabilities: BridgeCapabilities(readOnlyReason: "此会话尚未连接"))) == "此会话尚未连接")
        #expect(SessionText.messageHint(session(source: .other)) == "尚未连接 Codex 控制通道，请在电脑上继续操作")
        #expect(SessionText.messageHint(claude()) == "Claude 会把这句话当成另一个会话发来的消息，它不能用来批准任何东西")
    }

    @Test func aBlankReadOnlyReasonFallsBackToTheStandardHint() {
        #expect(SessionText.messageHint(session(capabilities: BridgeCapabilities(readOnlyReason: " "))) == "尚未连接 Codex 控制通道，请在电脑上继续操作")
        var noRoute = claude()
        noRoute.capabilities = BridgeCapabilities()
        #expect(SessionText.messageHint(noRoute) == "此会话暂时无法接收消息，请在电脑上继续操作")
    }

    @Test func waitingWithoutAnAnswerablePhoneCardPointsToTheDesktop() {
        let answerable = session(capabilities: BridgeCapabilities(canAnswer: true))
        #expect(SessionText.waitingHint(answerable, hasActionableRequest: true) == nil)
        #expect(SessionText.waitingHint(answerable, hasActionableRequest: false) == "请在电脑上的 Codex 会话中处理这次确认")
        #expect(SessionText.waitingHint(session(), hasActionableRequest: true) == "请在电脑上的 Codex 会话中处理这次确认")
        #expect(SessionText.waitingHint(session(state: .running), hasActionableRequest: false) == nil)
        #expect(SessionText.waitingHint(claude(), hasActionableRequest: false) == nil)
    }
}
