import Testing
@testable import ClawdCore

@Test func decisions() {
    let fresh = AppStatus(pid: 1, visible: true, heartbeat: 100_000, version: "1")
    #expect(ToggleDecision.decide(request: .toggle, status: nil, pidAlive: false, now: 0) == .launch(show: true))
    #expect(ToggleDecision.decide(request: .toggle, status: fresh, pidAlive: true, now: 101_000) == .send(show: false))
    #expect(ToggleDecision.decide(request: .toggle, status: fresh, pidAlive: true, now: 200_000) == .restart(show: false))
    #expect(ToggleDecision.decide(request: .hide, status: nil, pidAlive: false, now: 0) == .launch(show: false))
    #expect(ToggleDecision.message(for: .send(show: true)) == "Clawd 已显示")
}

@Test func decisionsCoverShowRequestAndDeadPid() {
    let fresh = AppStatus(pid: 1, visible: false, heartbeat: 100_000, version: "1")
    // A dead pid always launches, even if the status file says it's alive and fresh.
    #expect(ToggleDecision.decide(request: .show, status: fresh, pidAlive: false, now: 100_000) == .launch(show: true))
    #expect(ToggleDecision.decide(request: .hide, status: fresh, pidAlive: true, now: 100_500) == .send(show: false))
}

@Test func allMessages() {
    #expect(ToggleDecision.message(for: .launch(show: true)) == "Clawd 已显示")
    #expect(ToggleDecision.message(for: .launch(show: false)) == "Clawd 已隐藏")
    #expect(ToggleDecision.message(for: .send(show: false)) == "Clawd 已隐藏")
    #expect(ToggleDecision.message(for: .restart(show: true)) == "Clawd 无响应，已重启并显示")
    #expect(ToggleDecision.message(for: .restart(show: false)) == "Clawd 无响应，已重启并隐藏")
}
