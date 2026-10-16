import Foundation

/// What a `/pet` invocation (or its fallback `toggle` command) was asked to do.
public enum ToggleRequest: Sendable {
    case toggle, show, hide
}

/// The concrete action `HookCommand` should take in response to a `ToggleRequest`, given
/// the running app's last known status.
public enum ToggleAction: Equatable, Sendable {
    case launch(show: Bool)
    case send(show: Bool)
    case restart(show: Bool)
}

/// Decides how to fulfil a toggle request: launch the app if it isn't running, forward the
/// request to a live app via its URL scheme, or restart it first if it's gone unresponsive.
public enum ToggleDecision {
    /// How long (ms) since the last heartbeat before the app is considered hung.
    public static let staleAfterMs: Int64 = 10_000

    public static func decide(request: ToggleRequest, status: AppStatus?, pidAlive: Bool, now: Int64) -> ToggleAction {
        func show(currentlyVisible: Bool) -> Bool {
            switch request {
            case .show: return true
            case .hide: return false
            case .toggle: return !currentlyVisible
            }
        }

        guard let status, pidAlive else {
            return .launch(show: show(currentlyVisible: false))
        }
        if now - status.heartbeat > staleAfterMs {
            return .restart(show: show(currentlyVisible: status.visible))
        }
        return .send(show: show(currentlyVisible: status.visible))
    }

    public static func message(for action: ToggleAction) -> String {
        switch action {
        case .launch(let show), .send(let show):
            return show ? "Clawd 已显示" : "Clawd 已隐藏"
        case .restart(let show):
            return show ? "Clawd 无响应，已重启并显示" : "Clawd 无响应，已重启并隐藏"
        }
    }
}
