import CritterKit
import Foundation

/// How a session is described on screen (Android `SessionUi.kt`). State names are `PetState.label`.
public enum SessionText {
    /// Where a session runs, as phones say it. Not the desktop's `SessionSource.label`: "桌面版", "其它".
    public static func source(_ s: SessionSource) -> String {
        switch s {
        case .terminal: "终端"
        case .vscode: "VS Code"
        case .desktop: "桌面版"
        case .other: "其它"
        case .codex: "Codex"
        case .codexTerminal: "Codex · 终端"
        case .codexVSCode: "Codex · VS Code"
        case .codexDesktop: "Codex · Desktop"
        }
    }

    /// Old phones cached Codex as `other`; its namespaced id still identifies the provider.
    public static func isCodex(_ s: BridgeSession) -> Bool {
        s.source.isCodex || (s.source == .other && s.id.hasPrefix("codex-"))
    }

    public static func visibleSource(_ s: BridgeSession) -> SessionSource {
        s.source == .other && isCodex(s) ? .codex : s.source
    }

    /// Missing capabilities preserve the older Claude route; Codex needs a verified owner.
    public static func supportsMessages(_ s: BridgeSession) -> Bool {
        s.capabilities?.canSay ?? !isCodex(s)
    }

    public static func supportsAnswers(_ s: BridgeSession) -> Bool {
        s.capabilities?.canAnswer ?? !isCodex(s)
    }

    public static func canStopTurn(_ s: BridgeSession, online: Bool) -> Bool {
        online && s.capabilities?.canInterrupt == true
    }

    public static func messageHint(_ s: BridgeSession) -> String {
        if !supportsMessages(s) {
            if let reason = s.capabilities?.readOnlyReason, !isBlank(reason) { return reason }
            return isCodex(s) ? "尚未连接 Codex 控制通道，请在电脑上继续操作" : "此会话暂时无法接收消息，请在电脑上继续操作"
        }
        return isCodex(s) ? "发送到当前 Codex 会话" : "Claude 会把这句话当成另一个会话发来的消息，它不能用来批准任何东西"
    }

    public static func waitingHint(_ s: BridgeSession, hasActionableRequest: Bool) -> String? {
        isCodex(s) && s.state == .waiting && (!supportsAnswers(s) || !hasActionableRequest)
            ? "请在电脑上的 Codex 会话中处理这次确认" : nil
    }

    /// The last path component of `cwd` ("/Users/me/proj" -> "proj").
    public static func folderName(_ cwd: String) -> String {
        let trimmed = cwd.reversed().drop { $0 == "/" }.reversed()
        let name = trimmed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        return name.isEmpty ? cwd : name
    }

    /// "proj · main · 终端": folder, branch (left out when there is none), where it runs.
    public static func place(_ s: BridgeSession) -> String {
        var parts = [folderName(s.cwd)]
        if let branch = s.branch, !isBlank(branch) { parts.append(branch) }
        parts.append(source(visibleSource(s)))
        return parts.joined(separator: " · ")
    }

    /// What the session is doing: the detail line, falling back to the activity, then the state name.
    public static func doing(_ s: BridgeSession) -> String {
        if let detail = s.detail, !isBlank(detail) { return detail }
        if let activity = s.activity, !isBlank(activity) { return activity }
        return s.state.label
    }

    /// "42%", with "≈" in front when the Mac only estimated it.
    public static func contextPercent(_ c: BridgeContext) -> String {
        (c.estimated ? "≈" : "") + "\(LimitsText.roundedPercent(c.usedPercent))%"
    }

    public static func conn(_ state: ConnState) -> String {
        switch state {
        case .idle: "未连接"
        case .connecting: "连接中…"
        case .awaitingApproval: "请在 Mac 上点允许"
        case .connected: "已连接"
        case .offline: "未连接，正在重试"
        case .needsRepair(let reason): reason
        }
    }

    /// "刚刚", "5 分钟前", "3 小时前".
    public static func ago(_ then: Date, now: Date) -> String {
        let minutes = Int(min(max(now.timeIntervalSince(then) / 60, 0), 1e15))
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分钟前" }
        return "\(minutes / 60) 小时前"
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
