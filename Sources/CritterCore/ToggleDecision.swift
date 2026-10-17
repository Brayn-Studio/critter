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
    /// The heartbeat looks stale: send the request anyway and wait up to `probeTimeout` for
    /// a fresh heartbeat (the app writes one on every URL event), then settle on `.send` or
    /// `.restart` via `afterProbe`. Never a final action.
    case probe(show: Bool)
    case restart(show: Bool)
}

/// Decides how to fulfil a toggle request: launch the app if it isn't running, forward the
/// request to a live app via its URL scheme, or -- if its heartbeat has gone stale and it
/// doesn't answer a probe either -- restart it.
public enum ToggleDecision {
    /// How long (ms) since the last heartbeat before the app is suspected hung.
    public static let staleAfterMs: Int64 = 10_000
    /// How long a suspected-hung app gets to answer the probe with a fresh heartbeat.
    public static let probeTimeout: TimeInterval = 1.5

    /// Where Critter's executable sits inside its bundle (`CFBundleExecutable` = `Critter`).
    public static let appExecutableSuffix = "/Contents/MacOS/Critter"

    /// Whether the process now holding `status.pid` is the Critter that wrote `status`: alive,
    /// running Critter's own executable, and -- when the status recorded one -- started at the
    /// same time (within `StartupCleanup.startTimeToleranceSeconds`). app.json outlives the
    /// app (crash, `kill -9`, reboot) and pids get reused, so anything less could make `/pet`
    /// kill an unrelated process. Unconfirmed means "not Critter": the caller then merely
    /// launches the app, which is harmless if it was running after all.
    public static func isCritter(status: AppStatus, alive: Bool, executablePath: String?, startTime: Int64?) -> Bool {
        guard alive, let executablePath, executablePath.hasSuffix(appExecutableSuffix) else { return false }
        guard let recorded = status.startTime else { return true }
        guard let startTime else { return false }
        return abs(startTime - recorded) <= StartupCleanup.startTimeToleranceSeconds
    }

    /// - Parameter appRunning: `status.pid` is verifiably the running Critter (`isCritter`).
    public static func decide(request: ToggleRequest, status: AppStatus?, appRunning: Bool, now: Int64) -> ToggleAction {
        func show(currentlyVisible: Bool) -> Bool {
            switch request {
            case .show: return true
            case .hide: return false
            case .toggle: return !currentlyVisible
            }
        }

        guard let status, appRunning else {
            return .launch(show: show(currentlyVisible: false))
        }
        if now - status.heartbeat > staleAfterMs {
            return .probe(show: show(currentlyVisible: status.visible))
        }
        return .send(show: show(currentlyVisible: status.visible))
    }

    /// Phase two of `.probe`: an app that answered is merely slow (e.g. App Nap) and has
    /// already received the request; one that didn't is hung and gets restarted.
    public static func afterProbe(show: Bool, answered: Bool) -> ToggleAction {
        answered ? .send(show: show) : .restart(show: show)
    }

    /// Whether app.json shows a heartbeat newer than the one that looked stale -- written by
    /// that app's main thread (so it's responsive), or by a new instance (nothing to kill).
    public static func probeAnswered(before: AppStatus, after: AppStatus?) -> Bool {
        guard let after else { return false }
        return after.heartbeat > before.heartbeat
    }

    public static func message(for action: ToggleAction) -> String {
        switch action {
        case .launch(let show), .send(let show), .probe(let show):
            return show ? "Critter 已显示" : "Critter 已隐藏"
        case .restart(let show):
            return show ? "Critter 无响应，已重启并显示" : "Critter 无响应，已重启并隐藏"
        }
    }
}
