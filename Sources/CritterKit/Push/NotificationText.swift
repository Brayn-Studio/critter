import Foundation

/// The words of a notification and of the sessions and requests they are about (Android `Alerts.kt` and
/// `SessionUi.kt`). The Mac seals them into pushes (`PushContent`); the phone's `RequestText` and `SessionText`
/// show the same words on screen and forward here, so the two never differ.
public enum NotificationText {
    // MARK: - A request

    /// "critter 想 swift test": who is waiting and for what (Android `Alerts.requestTitle`). `what` is the
    /// request's summary, else its tool's name.
    public static func title(_ request: BridgePending, session: BridgeSession?) -> String {
        let name = session?.name ?? "会话"
        let what = isBlank(request.summary) ? request.toolName : request.summary
        switch request.kind {
        case .permission: return what.isEmpty ? "\(name) 想执行一个操作" : "\(name) 想 \(what)"
        case .question: return what.isEmpty ? "\(name) 有问题要问你" : "\(name) 问：\(what)"
        case .plan: return "\(name) 的计划等你批准"
        }
    }

    /// A request's notification text (Android `Alerts.requestText`): the command or path of a permission,
    /// otherwise the session's folder; nil when there is neither.
    public static func requestBody(_ request: BridgePending, session: BridgeSession?) -> String? {
        let body = request.kind == .permission ? permissionBody(request.input) : nil
        return body ?? session.map { folderName($0.cwd) }
    }

    /// The first of `command`, `file_path`, `url` that the request has (and is not blank).
    public static func permissionBody(_ input: JSONValue) -> String? {
        ["command", "file_path", "url"].lazy.compactMap { input[$0]?.stringValue }.first { !isBlank($0) }
    }

    /// Codex approvals accept only a decision; Claude's older requests also accept an optional reason.
    public static func acceptsDenyMessage(_ input: JSONValue) -> Bool {
        if case .bool(false)? = input["acceptsDenyMessage"] { return false }
        return true
    }

    // MARK: - A session

    /// "<名字> 等你确认（请在电脑上处理）": waiting for something only the Mac can answer (Android
    /// `Alerts.waitingNoticeTitle`).
    public static func waitingNoticeTitle(_ session: BridgeSession) -> String {
        "\(session.name) 等你确认（请在电脑上处理）"
    }

    /// What the waiting notice says under its title: what the session is doing, else its folder (Android).
    public static func waitingNoticeBody(_ session: BridgeSession) -> String {
        if let detail = session.detail, !isBlank(detail) { return detail }
        return folderName(session.cwd)
    }

    /// "<名字> <状态名>": a session finished or failed (Android `Alerts.postSessionResult`).
    public static func resultTitle(_ session: BridgeSession, state: PetState) -> String {
        "\(session.name) \(state.label)"
    }

    /// What the result notification says under its title: what the session last did (Android `detail`).
    public static func resultBody(_ session: BridgeSession) -> String {
        session.detail ?? ""
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

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
