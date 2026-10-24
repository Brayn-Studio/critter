import Foundation
import Testing
@testable import CritterCore

private let second: Int64 = 1000
private let minute: Int64 = 60 * second
private let hour: Int64 = 60 * minute
private let t0: Int64 = 1_760_000_000_000
/// When an activity started at `t0` is restarted.
private let restart = t0 + 7 * hour + 30 * minute

private func session(
    _ id: String, _ state: PetState, skin: String = "sprig", startedAt: Int64 = 1, name: String = "name"
) -> BridgeSession {
    BridgeSession(
        id: id, name: name, source: .terminal, state: state, detail: "detail of \(id)", activity: "activity", cwd: "/p/\(id)",
        branch: "main", skin: skin, eventTime: 5, startedAt: startedAt, tracked: true
    )
}

private func body(_ sessions: [BridgeSession], fiveHour: Double? = nil, sevenDay: Double? = nil) -> SnapshotBody {
    let limits = (fiveHour == nil && sevenDay == nil) ? nil : BridgeLimits(
        fiveHour: fiveHour.map { RateWindow(usedPercentage: $0, resetsAt: 9) },
        sevenDay: sevenDay.map { RateWindow(usedPercentage: $0, resetsAt: 9) }, updatedAt: 1
    )
    return SnapshotBody(
        sessions: sessions, limits: limits, pending: [],
        prefs: BridgePrefs(skin: "sprig", randomSkins: false, idleDim: 1.0, mergeThreshold: 4, soundTheme: "pixel")
    )
}

private func contentOf(_ snapshot: SnapshotBody) -> LiveActivityContent {
    LiveActivityPlanner().content(from: snapshot)
}

/// A content for `states` (one session each, in this order).
private func content(_ states: PetState...) -> LiveActivityContent {
    contentOf(body(states.enumerated().map { session("s\($0.offset)", $0.element, startedAt: Int64($0.offset)) }))
}

private func stamped(_ content: LiveActivityContent, _ now: Int64) -> LiveActivityContent {
    var copy = content
    copy.updatedAt = now
    return copy
}

private struct Phone {
    var enabled = true
    var startToken = true
    var activityToken: String?
}

private func next(
    _ planner: LiveActivityPlanner, _ content: LiveActivityContent, at now: Int64, _ phone: Phone = Phone()
) -> [LiveActivityAction] {
    planner.next(
        content: content, now: now, activityEnabled: phone.enabled, hasStartToken: phone.startToken,
        activityToken: phone.activityToken
    )
}

/// A planner whose activity is running on a phone that reports `token`, started at `t0` showing `shown`.
private func running(_ shown: LiveActivityContent, token: String = "tok1") -> (LiveActivityPlanner, Phone) {
    let planner = LiveActivityPlanner()
    #expect(next(planner, shown, at: t0) == [.start(stamped(shown, t0))])
    return (planner, Phone(activityToken: token))
}

// MARK: - The content

@Test func contentLeadsWithTheMostUrgentAndKeepsTwoBehind() {
    let snapshot = body([
        session("a", .running, skin: "run1", startedAt: 10),
        session("b", .done, skin: "done1", startedAt: 20),
        session("c", .waiting, skin: "late", startedAt: 300),
        session("d", .waiting, skin: "early", startedAt: 100),
        session("e", .error, skin: "err1", startedAt: 40),
        session("f", .idle, skin: "idle1", startedAt: 50),
    ], fiveHour: 41.6, sevenDay: 7.4)
    let content = contentOf(snapshot)
    // Most urgent first (waiting > error > done > running > idle); the earlier-started of equals in front.
    #expect(content.lead == PetBadge(skin: "early", state: .waiting))
    #expect(content.back == [PetBadge(skin: "late", state: .waiting), PetBadge(skin: "err1", state: .error)])
    #expect(content.total == 6)
    #expect(content.counts == [
        StateCount(state: .waiting, count: 2), StateCount(state: .error, count: 1), StateCount(state: .done, count: 1),
        StateCount(state: .running, count: 1), StateCount(state: .idle, count: 1),
    ])
    #expect(content.fiveHour == 42 && content.sevenDay == 7)
}

@Test func contentOfNoSessionsIsEmpty() {
    let content = contentOf(body([]))
    #expect(content.total == 0 && content.lead == nil && content.back.isEmpty && content.counts.isEmpty)
    #expect(content.fiveHour == nil && content.sevenDay == nil)
}

@Test func contentFollowsTheFlocksOrderForLeadAndBack() {
    // The lead is the one the Mac's merged flock puts in front (and the phone's `PhoneFlock` does, by the same rule).
    let sessions = [
        session("a", .done, startedAt: 5), session("b", .running, startedAt: 1), session("c", .done, startedAt: 2),
        session("d", .error, startedAt: 9), session("e", .error, startedAt: 3),
    ]
    let pets = sessions.map {
        PetSession(
            id: $0.id, name: $0.name, source: $0.source, state: $0.state, detail: nil, cwd: $0.cwd, pid: nil,
            transcriptPath: nil, tracked: true, eventTime: $0.eventTime, sortKey: $0.startedAt
        )
    }
    guard case .merged(let lead, let counts, let total) = FlockModel.merged(pets) else {
        Issue.record("not merged")
        return
    }
    let content = contentOf(body(sessions))
    #expect(lead.id == "e")
    #expect(content.lead == PetBadge(skin: "sprig", state: lead.state))
    #expect(content.counts == counts)
    #expect(content.total == total)
    // Behind the lead: the rest in the same order -- the other error, then the dones, earliest started first.
    #expect(content.back.map(\.state) == [.error, .done])
}

@Test func percentagesAreRoundedAndKeptInRange() {
    #expect(contentOf(body([session("a", .idle)], fiveHour: 12.5, sevenDay: 99.4)).fiveHour == 13)
    #expect(contentOf(body([session("a", .idle)], fiveHour: 0.4, sevenDay: 150)).sevenDay == 100)
    #expect(contentOf(body([session("a", .idle)], fiveHour: 0.4)).sevenDay == nil)
    #expect(contentOf(body([session("a", .idle)], fiveHour: .nan)).fiveHour == nil)
}

/// Review focus 2 for the Live Activity: counts, skin names, states, percentages and times only.
@Test func activityContentNeverCarriesText() throws {
    let snapshot = body([
        session("id-secret", .waiting, skin: "sprig", name: "Secret Name ÄÖ"),
        session("other", .running, skin: "mint", name: "Secret Folder"),
    ], fiveHour: 10, sevenDay: 20)
    let content = contentOf(snapshot)
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(content))
    var strings: [String] = []
    func collect(_ value: Any) {
        if let string = value as? String { strings.append(string) }
        if let array = value as? [Any] { array.forEach(collect) }
        if let dictionary = value as? [String: Any] { dictionary.values.forEach(collect) }
    }
    collect(json)
    // Every string in it is a skin name or a state; nothing else (no session name, id, path, branch, detail).
    #expect(!strings.isEmpty)
    #expect(Set(strings).isSubset(of: ["sprig", "mint", "waiting", "running"]), "\(strings)")
}

// MARK: - Starting

@Test func activityStartsWhenThereAreSessionsAndAStartToken() {
    let planner = LiveActivityPlanner()
    let c = content(.running, .waiting)
    #expect(next(planner, c, at: t0) == [.start(stamped(c, t0))])
}

@Test func theStartedContentIsStampedWithTheTimeItIsSent() {
    let planner = LiveActivityPlanner()
    let c = content(.running)
    guard case .start(let started)? = next(planner, c, at: t0).first else {
        Issue.record("no start")
        return
    }
    #expect(started.updatedAt == t0)
}

@Test func nothingStartsWithoutSessionsOrAStartTokenOrWhileOff() {
    let c = content(.running)
    #expect(next(LiveActivityPlanner(), c, at: t0, Phone(startToken: false)).isEmpty)
    #expect(next(LiveActivityPlanner(), content(), at: t0).isEmpty)
    #expect(next(LiveActivityPlanner(), c, at: t0, Phone(enabled: false)).isEmpty)
    // The start token arriving later starts it.
    let planner = LiveActivityPlanner()
    #expect(next(planner, c, at: t0, Phone(startToken: false)).isEmpty)
    #expect(next(planner, c, at: t0 + second) == [.start(stamped(c, t0 + second))])
}

@Test func noSecondStartWhileTheActivityTokenIsOnItsWay() {
    let planner = LiveActivityPlanner()
    let c = content(.running)
    #expect(next(planner, c, at: t0).count == 1)
    // Snapshots keep coming; the phone has not reported its activity yet. A second start would make a second activity.
    #expect(next(planner, c, at: t0 + second).isEmpty)
    #expect(next(planner, content(.waiting), at: t0 + 5 * second).isEmpty)
    #expect(next(planner, content(.waiting), at: t0 + 2 * hour).isEmpty)
}

@Test func anActivityTheAppStartedItselfIsUpdatedNotStarted() {
    let planner = LiveActivityPlanner()
    let c = content(.running)
    // Its token is known, the Mac has never sent it anything: it gets the current content once.
    #expect(next(planner, c, at: t0, Phone(activityToken: "tok1")) == [.update(stamped(c, t0), priority: 5)])
    #expect(next(planner, c, at: t0 + second, Phone(activityToken: "tok1")).isEmpty)
}

// MARK: - Updating

@Test func activityUpdatesOnlyWhenTheContentChanges() {
    let shown = content(.running)
    let (planner, phone) = running(shown)
    #expect(next(planner, shown, at: t0 + minute, phone).isEmpty)
    // Another snapshot, same Critters and numbers: nothing to send, even though sessions' times moved on.
    #expect(next(planner, stamped(shown, t0 + 2 * minute), at: t0 + 2 * minute, phone).isEmpty)
    let changed = content(.done)
    #expect(next(planner, changed, at: t0 + 3 * minute, phone) == [.update(stamped(changed, t0 + 3 * minute), priority: 5)])
    #expect(next(planner, changed, at: t0 + 4 * minute, phone).isEmpty)
}

@Test func moreWaitingIsUrgentOtherChangesAreThrottledTo10s() {
    let shown = content(.running, .running)
    let (planner, phone) = running(shown)

    // Within 10 seconds of the last send, an ordinary change waits for the end of the period.
    let done = content(.done, .running)
    #expect(next(planner, done, at: t0 + 3 * second, phone).isEmpty)
    #expect(planner.nextDeadline() == t0 + 10 * second)
    // More changes meanwhile: only the last one goes out, when the period is over.
    let errored = content(.error, .running)
    #expect(next(planner, errored, at: t0 + 6 * second, phone).isEmpty)
    #expect(next(planner, errored, at: t0 + 9 * second + 999, phone).isEmpty)
    #expect(next(planner, errored, at: t0 + 10 * second, phone) == [.update(stamped(errored, t0 + 10 * second), priority: 5)])
    // Nothing waits now but the refresh of a quiet activity.
    #expect(planner.nextDeadline() == t0 + 10 * second + LiveActivityPlanner.refresh)

    // A session starts waiting: priority 10, at once, inside the period.
    let waiting = content(.waiting, .running)
    #expect(next(planner, waiting, at: t0 + 11 * second, phone) == [.update(stamped(waiting, t0 + 11 * second), priority: 10)])
    // More waiting again.
    let twoWaiting = content(.waiting, .waiting)
    #expect(next(planner, twoWaiting, at: t0 + 12 * second, phone) == [.update(stamped(twoWaiting, t0 + 12 * second), priority: 10)])
    // Less waiting is an ordinary change, throttled from the last send.
    let fewer = content(.waiting, .running)
    #expect(next(planner, fewer, at: t0 + 13 * second, phone).isEmpty)
    #expect(next(planner, fewer, at: t0 + 22 * second, phone) == [.update(stamped(fewer, t0 + 22 * second), priority: 5)])
}

@Test func aChangeThatIsUndoneWithinThePeriodSendsNothing() {
    let shown = content(.running)
    let (planner, phone) = running(shown)
    #expect(next(planner, content(.done), at: t0 + 2 * second, phone).isEmpty)
    #expect(planner.nextDeadline() == t0 + 10 * second)
    #expect(next(planner, shown, at: t0 + 10 * second, phone).isEmpty)
    // The refresh counts from the last push (the start).
    #expect(planner.nextDeadline() == t0 + LiveActivityPlanner.refresh)
}

@Test func updatesNeedTheActivityToken() {
    let shown = content(.running)
    let (planner, _) = running(shown)
    // The phone has not told the Mac the token yet: nothing can be updated.
    #expect(next(planner, content(.waiting), at: t0 + minute).isEmpty)
    // When it does, the content that differs is sent.
    let waiting = content(.waiting)
    #expect(next(planner, waiting, at: t0 + 2 * minute, Phone(activityToken: "tok1")) == [.update(stamped(waiting, t0 + 2 * minute), priority: 10)])
}

// MARK: - Ending

@Test func activityEndsFiveMinutesAfterTheLastSession() {
    let shown = content(.running)
    let (planner, phone) = running(shown)
    let none = content()
    let gone = t0 + minute
    // The activity shows the empty state meanwhile (an ordinary change), and the end is five minutes off.
    #expect(next(planner, none, at: gone, phone) == [.update(stamped(none, gone), priority: 5)])
    #expect(planner.nextDeadline() == gone + 5 * minute)
    #expect(next(planner, none, at: gone + 5 * minute - 1, phone).isEmpty)
    #expect(next(planner, none, at: gone + 5 * minute, phone) == [.end(dismissAt: gone + 5 * minute)])
    #expect(planner.nextDeadline() == nil)
    // Nothing more once it ended, even though the phone still reports the old token for a while.
    #expect(next(planner, none, at: gone + 6 * minute, phone).isEmpty)
    // Sessions come back: a new activity, not an update of the dead one -- ten minutes after the last start.
    let again = content(.running)
    #expect(next(planner, again, at: gone + 7 * minute, phone).isEmpty)
    #expect(next(planner, again, at: gone + 9 * minute, phone) == [.start(stamped(again, gone + 9 * minute))])
}

@Test func sessionsBackWithinFiveMinutesKeepTheActivity() {
    let shown = content(.running)
    let (planner, phone) = running(shown)
    let none = content()
    _ = next(planner, none, at: t0 + 20 * second, phone)
    #expect(planner.nextDeadline() == t0 + 20 * second + 5 * minute)
    let back = content(.running)
    #expect(next(planner, back, at: t0 + 2 * minute, phone) == [.update(stamped(back, t0 + 2 * minute), priority: 5)])
    #expect(planner.nextDeadline() == t0 + 2 * minute + LiveActivityPlanner.refresh)
    #expect(next(planner, back, at: t0 + 8 * minute, phone).isEmpty)
}

@Test func theFiveMinutesRunFromWhenTheSessionsWentNotFromTheLastSnapshot() {
    let (planner, phone) = running(content(.running))
    let none = content()
    _ = next(planner, none, at: t0 + minute, phone)
    // More empty snapshots do not push the end back.
    _ = next(planner, none, at: t0 + 3 * minute, phone)
    #expect(planner.nextDeadline() == t0 + 6 * minute)
}

@Test func turningItOffEndsTheActivity() {
    let (planner, phone) = running(content(.running))
    var off = phone
    off.enabled = false
    #expect(next(planner, content(.running), at: t0 + minute, off) == [.end(dismissAt: t0 + minute)])
    #expect(next(planner, content(.running), at: t0 + 2 * minute, off).isEmpty)
    #expect(planner.nextDeadline() == nil)
    // Turned back on, with the old token gone: it starts again, ten minutes after the last start.
    let c = content(.running)
    #expect(next(planner, c, at: t0 + 3 * minute, Phone()).isEmpty)
    #expect(next(planner, c, at: t0 + 10 * minute, Phone()) == [.start(stamped(c, t0 + 10 * minute))])
}

@Test func turningItOffWithNoActivityKnownSendsNothing() {
    let planner = LiveActivityPlanner()
    #expect(next(planner, content(.running), at: t0, Phone(enabled: false)).isEmpty)
    #expect(planner.nextDeadline() == nil)
}

@Test func noActivityMeansNoEndAfterTheSessionsGo() {
    // A start that no token ever followed: nothing to end, and nothing happens at the deadline either.
    let planner = LiveActivityPlanner()
    _ = next(planner, content(.running), at: t0)
    #expect(next(planner, content(), at: t0 + minute).isEmpty)
    #expect(next(planner, content(), at: t0 + 10 * minute).isEmpty)
    // A later session does not start another while that one may still be on the screen: not until its token
    // comes, or 8 hours have passed (the system ends an activity by then).
    let c = content(.waiting)
    #expect(next(planner, c, at: t0 + 11 * minute).isEmpty)
    #expect(planner.unconfirmedStartAt == t0)
    #expect(next(planner, c, at: t0 + 8 * hour - 1).isEmpty)
    #expect(next(planner, c, at: t0 + 8 * hour) == [.start(stamped(c, t0 + 8 * hour))])
    #expect(planner.unconfirmedStartAt == t0 + 8 * hour)
}

@Test func aStartWhoseTokenNeverCameHoldsOffTheNextAcrossARestart() {
    let before = LiveActivityPlanner()
    _ = next(before, content(.running), at: t0)
    #expect(before.unconfirmedStartAt == t0)
    // Critter restarts; the device's record brought the start back.
    let after = LiveActivityPlanner(unconfirmedStartAt: before.unconfirmedStartAt)
    let c = content(.waiting)
    #expect(next(after, c, at: t0 + hour).isEmpty)
    #expect(next(after, c, at: t0 + 8 * hour) == [.start(stamped(c, t0 + 8 * hour))])
    // Without one, a fresh planner starts at once.
    #expect(next(LiveActivityPlanner(), c, at: t0 + hour) == [.start(stamped(c, t0 + hour))])
}

@Test func theTokenArrivingConfirmsTheStart() {
    let planner = LiveActivityPlanner()
    _ = next(planner, content(.running), at: t0)
    _ = next(planner, content(.running), at: t0 + 5 * second, Phone(activityToken: "tok1"))
    #expect(planner.unconfirmedStartAt == nil)
}

@Test func turningItOffDropsAStartWaitingForItsToken() {
    let planner = LiveActivityPlanner()
    let c = content(.running)
    _ = next(planner, c, at: t0)
    #expect(next(planner, c, at: t0 + minute, Phone(enabled: false)).isEmpty)
    #expect(planner.unconfirmedStartAt == nil)
    // On again: the usual ten minutes after the last start.
    #expect(next(planner, c, at: t0 + 5 * minute).isEmpty)
    #expect(next(planner, c, at: t0 + 10 * minute) == [.start(stamped(c, t0 + 10 * minute))])
}

@Test func aTokenTheMacEndedStaysEndedWhenItIsReportedAgainLater() {
    let shown = content(.running)
    let (planner, phone) = running(shown)
    var off = phone
    off.enabled = false
    #expect(next(planner, shown, at: t0 + minute, off) == [.end(dismissAt: t0 + minute)])
    // The Mac forgot the token in the registry; then an old registration brings it back.
    #expect(next(planner, shown, at: t0 + 2 * minute, Phone()).isEmpty)
    let waiting = content(.waiting)
    #expect(next(planner, waiting, at: t0 + 3 * minute, phone).isEmpty)
    // It stands for no activity: a new one is started in its place, in time.
    #expect(next(planner, waiting, at: t0 + 10 * minute, phone) == [.start(stamped(waiting, t0 + 10 * minute))])
}

@Test func anActivityTheUserSwipedAwayIsStartedAgainButNotAtOnce() {
    let shown = content(.running)
    let (planner, phone) = running(shown)
    #expect(next(planner, shown, at: t0 + minute, phone).isEmpty)
    // The phone reports no activity any more. The Mac cannot tell a swipe from an end: it starts again, but not
    // within ten minutes of the last start, or the user could never get rid of it.
    let c = content(.waiting)
    #expect(next(planner, c, at: t0 + 2 * minute, Phone()).isEmpty)
    #expect(next(planner, c, at: t0 + 10 * minute - 1, Phone()).isEmpty)
    #expect(next(planner, c, at: t0 + 10 * minute, Phone()) == [.start(stamped(c, t0 + 10 * minute))])
}

// MARK: - The 8-hour limit

@Test func activityIsRestartedBefore8Hours() {
    let shown = content(.running)
    let (planner, phone) = running(shown)
    #expect(planner.nextDeadline() == restart)
    // Before the 7.5 hours a quiet activity only gets its refresh (the content as it was sent), no end.
    #expect(next(planner, shown, at: restart - 1, phone) == [.update(stamped(shown, t0), priority: 5)])

    let at = restart
    #expect(next(planner, shown, at: at, phone) == [.end(dismissAt: at), .start(stamped(shown, at))])
    // The phone still reports the old token for a moment: it is not mistaken for the new activity, nor ended twice.
    #expect(next(planner, shown, at: at + second, phone).isEmpty)
    // The new activity's token arrives; its 7.5 hours start from the restart.
    var fresh = phone
    fresh.activityToken = "tok2"
    #expect(next(planner, shown, at: at + 5 * second, fresh).isEmpty)
    #expect(planner.nextDeadline() == at + LiveActivityPlanner.refresh)
    #expect(next(planner, shown, at: at + 7 * hour + 30 * minute - 1, fresh) == [.update(stamped(shown, at), priority: 5)])
    let again = at + 7 * hour + 30 * minute
    #expect(next(planner, shown, at: again, fresh) == [.end(dismissAt: again), .start(stamped(shown, again))])
}

@Test func withoutAStartTokenTheOldActivityIsLeftToRun() {
    let shown = content(.running)
    let (planner, phone) = running(shown)
    var noStart = phone
    noStart.startToken = false
    // Not ended (nothing could replace it): only refreshed, as any quiet activity.
    #expect(next(planner, shown, at: restart, noStart) == [.update(stamped(shown, t0), priority: 5)])
}

@Test func aRestartThatCannotHappenIsNotDueOverAndOver() {
    let shown = content(.running)
    let (planner, phone) = running(shown)
    var noStart = phone
    noStart.startToken = false
    #expect(next(planner, shown, at: restart, noStart) == [.update(stamped(shown, t0), priority: 5)])
    // Nothing more can be done about its age without a start token: the caller's timer must not fire again and
    // again on a deadline that has passed. What is left is the next refresh.
    #expect(planner.nextDeadline() == restart + LiveActivityPlanner.refresh)
    // The old activity still gets its updates.
    let waiting = content(.waiting)
    #expect(next(planner, waiting, at: restart + second, noStart) == [.update(stamped(waiting, restart + second), priority: 10)])
    #expect(planner.nextDeadline() == restart + second + LiveActivityPlanner.refresh)
    // A start token comes with the next registration: it is replaced on the next snapshot.
    let at = restart + 2 * second
    #expect(next(planner, waiting, at: at, phone) == [.end(dismissAt: at), .start(stamped(waiting, at))])
    #expect(planner.nextDeadline() == at + 7 * hour + 30 * minute)
}

@Test func anActivityTheAppStartedIsTimedFromWhenTheMacFirstSawIt() {
    let planner = LiveActivityPlanner()
    let c = content(.running)
    _ = next(planner, c, at: t0, Phone(activityToken: "app"))
    #expect(planner.nextDeadline() == t0 + LiveActivityPlanner.refresh)
    // Its 7.5 hours count from that moment.
    #expect(next(planner, c, at: restart - 1, Phone(activityToken: "app")) == [.update(stamped(c, t0), priority: 5)])
    #expect(next(planner, c, at: restart, Phone(activityToken: "app")) == [.end(dismissAt: restart), .start(stamped(c, restart))])
}

// MARK: - A quiet activity is refreshed

/// Sessions are all there but nothing changes: about every 12 minutes the Mac sends the content again, as it was (its
/// time included), at low priority, so that its stale date moves on and a true activity does not turn grey.
@Test func aQuietActivityIsRefreshedEvery12Minutes() {
    let shown = content(.running)
    let (planner, phone) = running(shown)
    let first = stamped(shown, t0)
    #expect(next(planner, shown, at: t0 + second, phone).isEmpty)
    #expect(planner.nextDeadline() == t0 + LiveActivityPlanner.refresh)
    #expect(next(planner, shown, at: t0 + LiveActivityPlanner.refresh - 1, phone).isEmpty)
    #expect(next(planner, stamped(shown, t0 + 5 * minute), at: t0 + LiveActivityPlanner.refresh, phone)
        == [.update(first, priority: 5)])
    // The next one 12 minutes after that.
    #expect(planner.nextDeadline() == t0 + 2 * LiveActivityPlanner.refresh)
    #expect(next(planner, shown, at: t0 + 2 * LiveActivityPlanner.refresh - 1, phone).isEmpty)
    #expect(next(planner, shown, at: t0 + 2 * LiveActivityPlanner.refresh, phone) == [.update(first, priority: 5)])
}

@Test func noRefreshWhileTheContentKeepsChanging() {
    let (planner, phone) = running(content(.running))
    // A change every 5 minutes is sent as a change; the refresh always counts from the last push.
    let states: [PetState] = [.done, .running, .error, .running, .done]
    for (i, state) in states.enumerated() {
        let at = t0 + Int64(i + 1) * 5 * minute
        let c = content(state)
        #expect(next(planner, c, at: at, phone) == [.update(stamped(c, at), priority: 5)])
        #expect(planner.nextDeadline() == at + LiveActivityPlanner.refresh)
    }
    // A change 5 s before a refresh would be due: the refresh is put off, the throttle kept.
    let last = t0 + 25 * minute
    let late = content(.idle)
    #expect(next(planner, late, at: last + LiveActivityPlanner.refresh - 5 * second, phone)
        == [.update(stamped(late, last + LiveActivityPlanner.refresh - 5 * second), priority: 5)])
    #expect(next(planner, late, at: last + LiveActivityPlanner.refresh, phone).isEmpty)
}

@Test func noRefreshWithoutSessionsOrAnActivityItsTokenCameFor() {
    // No sessions: the empty content is not refreshed, the activity ends five minutes on.
    let (empty, phone) = running(content(.running))
    let none = content()
    _ = next(empty, none, at: t0 + minute, phone)
    #expect(empty.nextDeadline() == t0 + 6 * minute)
    // A start whose token never came: nothing to refresh, no refresh deadline.
    let waitingForToken = LiveActivityPlanner()
    let c = content(.running)
    _ = next(waitingForToken, c, at: t0)
    #expect(waitingForToken.nextDeadline() == restart)
    #expect(next(waitingForToken, c, at: t0 + LiveActivityPlanner.refresh).isEmpty)
    // No activity at all (switched off): nothing.
    let off = LiveActivityPlanner()
    #expect(next(off, c, at: t0, Phone(enabled: false)).isEmpty)
    #expect(off.nextDeadline() == nil)
}

// MARK: - Deadlines

@Test func thereIsNoDeadlineWhenNothingIsWaitingForTime() {
    let planner = LiveActivityPlanner()
    #expect(planner.nextDeadline() == nil)
    let (started, _) = running(content(.running))
    // A running activity has one: the 8-hour restart.
    #expect(started.nextDeadline() == restart)
}

@Test func theEarliestDeadlineWins() {
    let (planner, phone) = running(content(.running))
    _ = next(planner, content(), at: t0 + 2 * second, phone)
    // The throttled empty-state update is due at +10s, before the 5-minute end.
    #expect(planner.nextDeadline() == t0 + 10 * second)
    _ = next(planner, content(), at: t0 + 10 * second, phone)
    #expect(planner.nextDeadline() == t0 + 2 * second + 5 * minute)
}

// MARK: - Staleness

@Test func theStaleDateIs15MinutesAfterSending() throws {
    let message = try PushContent.liveActivity(.update(content(.running), priority: 5), now: t0)
    let aps = try #require((try JSONSerialization.jsonObject(with: message.payload) as? [String: Any])?["aps"] as? [String: Any])
    #expect(aps["stale-date"] as? Int == Int(t0 / 1000) + 15 * 60)
}

@Test func aRefusedStartHoldsNothingOff() {
    let planner = LiveActivityPlanner()
    let c = content(.running)
    _ = next(planner, c, at: t0)
    // APNs refused the push-to-start: there is no activity to wait for.
    planner.startWasRefused()
    #expect(planner.unconfirmedStartAt == nil)
    #expect(next(planner, c, at: t0 + second) == [.start(stamped(c, t0 + second))])
}

@Test func aStartThatWentNowhereHoldsOffOnlyTheUsualTenMinutes() {
    let planner = LiveActivityPlanner()
    let c = content(.running)
    _ = next(planner, c, at: t0)
    // APNs refused the setup or the push, or the network failed: no activity is waiting for its token, so nothing
    // is held off for 8 hours. The push may have got through before the network failed: the ten minutes between
    // starts still count.
    planner.startNotDelivered()
    #expect(planner.unconfirmedStartAt == nil)
    #expect(next(planner, c, at: t0 + second).isEmpty)
    #expect(next(planner, c, at: t0 + 10 * minute) == [.start(stamped(c, t0 + 10 * minute))])
    // A start whose token came meanwhile was delivered: nothing changes.
    _ = next(planner, c, at: t0 + 10 * minute + second, Phone(activityToken: "tok1"))
    planner.startNotDelivered()
    #expect(next(planner, content(.waiting), at: t0 + 11 * minute, Phone(activityToken: "tok1")).count == 1)
}

@Test func aStartWhoseTokenNeverCameIsDueAgainAt8Hours() {
    let planner = LiveActivityPlanner()
    let c = content(.running)
    _ = next(planner, c, at: t0)
    #expect(planner.nextDeadline() == restart)
    // At 7.5 hours the Mac stops believing in it, but a start is not allowed before 8: that moment is a deadline,
    // so the start does not wait for the next snapshot.
    #expect(next(planner, c, at: restart).isEmpty)
    #expect(planner.nextDeadline() == t0 + 8 * hour)
    #expect(next(planner, c, at: t0 + 8 * hour) == [.start(stamped(c, t0 + 8 * hour))])
}

@Test func the8HoursOfAStartWhoseTokenNeverCameAreDueOnce() {
    // Critter restarts with a start kept from before.
    let planner = LiveActivityPlanner(unconfirmedStartAt: t0)
    #expect(planner.nextDeadline() == t0 + 8 * hour)
    // At 8 hours there are no sessions: nothing to start, and the start no longer holds anything off -- nor is it
    // due again, or the caller's timer would fire on it over and over.
    #expect(next(planner, content(), at: t0 + 8 * hour).isEmpty)
    #expect(planner.unconfirmedStartAt == nil)
    #expect(planner.nextDeadline() == nil)
    let c = content(.waiting)
    #expect(next(planner, c, at: t0 + 9 * hour) == [.start(stamped(c, t0 + 9 * hour))])
}

// MARK: - One rule for the Mac and the phone

/// The Mac's content is the assembly in CritterKit the phone uses as well (`LiveActivityContent(snapshot:)`).
@Test func theMacsContentIsTheSharedAssembly() {
    let snapshots = [
        body([]),
        body([session("a", .idle)], fiveHour: 12.5),
        body([
            session("a", .done, skin: "peep", startedAt: 5), session("b", .running, skin: "mochi", startedAt: 1),
            session("c", .done, startedAt: 2), session("d", .error, skin: "bristle", startedAt: 9),
            session("e", .error, startedAt: 3), session("f", .waiting, skin: "frill", startedAt: 7),
        ], fiveHour: 99.5, sevenDay: 0.4),
    ]
    for snapshot in snapshots {
        for updatedAt: Int64 in [0, 1_760_000_000_000] {
            #expect(LiveActivityPlanner().content(from: snapshot, updatedAt: updatedAt)
                == LiveActivityContent(snapshot: snapshot, updatedAt: updatedAt))
        }
    }
}
