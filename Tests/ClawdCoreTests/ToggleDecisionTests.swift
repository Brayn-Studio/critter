import Testing
@testable import ClawdCore

@Test func decisions() {
    let fresh = AppStatus(pid: 1, visible: true, heartbeat: 100_000, version: "1")
    #expect(ToggleDecision.decide(request: .toggle, status: nil, appRunning: false, now: 0) == .launch(show: true))
    #expect(ToggleDecision.decide(request: .toggle, status: fresh, appRunning: true, now: 101_000) == .send(show: false))
    // A stale heartbeat is only a suspicion (App Nap can delay it): probe before restarting.
    #expect(ToggleDecision.decide(request: .toggle, status: fresh, appRunning: true, now: 200_000) == .probe(show: false))
    #expect(ToggleDecision.decide(request: .hide, status: nil, appRunning: false, now: 0) == .launch(show: false))
    #expect(ToggleDecision.message(for: .send(show: true)) == "Clawd 已显示")
}

@Test func decisionsCoverShowRequestAndDeadPid() {
    let fresh = AppStatus(pid: 1, visible: false, heartbeat: 100_000, version: "1")
    // A dead pid always launches, even if the status file says it's alive and fresh.
    #expect(ToggleDecision.decide(request: .show, status: fresh, appRunning: false, now: 100_000) == .launch(show: true))
    #expect(ToggleDecision.decide(request: .hide, status: fresh, appRunning: true, now: 100_500) == .send(show: false))
}

@Test func allMessages() {
    #expect(ToggleDecision.message(for: .launch(show: true)) == "Clawd 已显示")
    #expect(ToggleDecision.message(for: .launch(show: false)) == "Clawd 已隐藏")
    #expect(ToggleDecision.message(for: .send(show: false)) == "Clawd 已隐藏")
    #expect(ToggleDecision.message(for: .restart(show: true)) == "Clawd 无响应，已重启并显示")
    #expect(ToggleDecision.message(for: .restart(show: false)) == "Clawd 无响应，已重启并隐藏")
}

/// F1: the pid in app.json may outlive Clawd (quit, crash, reboot) and be handed to any
/// other process. Only a live process running Clawd's own executable -- and, when the
/// status recorded one, with the same start time -- counts as the running app.
@Test func identityRequiresClawdExecutableAndMatchingStartTime() {
    let withStart = AppStatus(pid: 50, visible: true, heartbeat: 0, version: "1", startTime: 1_000)
    let legacy = AppStatus(pid: 50, visible: true, heartbeat: 0, version: "1")
    let clawd = "/Users/u/Applications/Clawd.app/Contents/MacOS/Clawd"

    #expect(ToggleDecision.isClawd(status: withStart, alive: true, executablePath: clawd, startTime: 1_000))
    #expect(ToggleDecision.isClawd(status: withStart, alive: true, executablePath: clawd, startTime: 1_002))
    #expect(ToggleDecision.isClawd(status: legacy, alive: true, executablePath: clawd, startTime: 1_000))

    // Gone.
    #expect(!ToggleDecision.isClawd(status: withStart, alive: false, executablePath: clawd, startTime: 1_000))
    // Alive, but some other program holds the pid now (reboot, pid wrap).
    let finder = "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
    #expect(!ToggleDecision.isClawd(status: withStart, alive: true, executablePath: finder, startTime: 1_000))
    #expect(!ToggleDecision.isClawd(status: legacy, alive: true, executablePath: finder, startTime: nil))
    #expect(!ToggleDecision.isClawd(status: legacy, alive: true, executablePath: nil, startTime: nil))
    #expect(!ToggleDecision.isClawd(status: legacy, alive: true, executablePath: "/tmp/Clawd.app/Contents/MacOS/ClawdHelper", startTime: nil))
    #expect(!ToggleDecision.isClawd(status: legacy, alive: true, executablePath: "/Users/u/clawd/.build/release/Clawd", startTime: nil))
    // A Clawd, but not the instance that wrote the status (it started later).
    #expect(!ToggleDecision.isClawd(status: withStart, alive: true, executablePath: clawd, startTime: 5_000))
    // The status names a start time we can no longer read: unconfirmed, so not Clawd.
    #expect(!ToggleDecision.isClawd(status: withStart, alive: true, executablePath: clawd, startTime: nil))
}

/// F3: an App-Napped (or merely busy) Clawd answers the URL it is sent by writing a fresh
/// heartbeat; only one that doesn't within the probe window is restarted.
@Test func probeRestartsOnlyWithoutAFreshHeartbeat() {
    #expect(ToggleDecision.afterProbe(show: true, answered: true) == .send(show: true))
    #expect(ToggleDecision.afterProbe(show: false, answered: true) == .send(show: false))
    #expect(ToggleDecision.afterProbe(show: true, answered: false) == .restart(show: true))
    #expect(ToggleDecision.afterProbe(show: false, answered: false) == .restart(show: false))

    let before = AppStatus(pid: 7, visible: true, heartbeat: 1_000, version: "1", startTime: 5)
    #expect(!ToggleDecision.probeAnswered(before: before, after: nil))
    #expect(!ToggleDecision.probeAnswered(before: before, after: before))
    var newer = before
    newer.heartbeat = 1_001
    #expect(ToggleDecision.probeAnswered(before: before, after: newer))
    // A brand-new instance answering also counts: there's nothing hung left to kill.
    let relaunched = AppStatus(pid: 8, visible: false, heartbeat: 2_000, version: "1", startTime: 9)
    #expect(ToggleDecision.probeAnswered(before: before, after: relaunched))
    #expect(ToggleDecision.probeTimeout == 1.5)
}
