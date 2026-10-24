import Foundation
import Testing
@testable import CritterCore

// `AlertPlannerTest.kt` without the pile and the buzz, plus the rules the Mac adds: the first snapshot of a
// fresh or reset tracker only records (spec 6.3), and a request is pushed once.

private func session(_ id: String, _ state: PetState = .idle) -> BridgeSession {
    BridgeSession(
        id: id, name: id, source: .terminal, state: state, cwd: "/Users/me/proj", skin: "sprig",
        eventTime: 1, startedAt: 1, tracked: true
    )
}

private func pending(_ requestId: String, _ sessionId: String) -> BridgePending {
    BridgePending(
        requestId: requestId, sessionId: sessionId, kind: .permission, toolName: "Bash", summary: "ls",
        input: .null, createdAt: 1, expiresAt: nil
    )
}

private func body(_ sessions: [BridgeSession], _ pending: [BridgePending] = []) -> SnapshotBody {
    SnapshotBody(
        sessions: sessions, pending: pending,
        prefs: BridgePrefs(skin: "sprig", randomSkins: false, idleDim: 1.0, mergeThreshold: 4, soundTheme: "pixel")
    )
}

private let off = PushPrefs()
private let both = PushPrefs(notifyDone: true, notifyError: true)

/// A tracker that has already taken `first`, so the next snapshot is judged against it.
private func tracker(_ prefs: PushPrefs = off, after first: SnapshotBody) -> PushTracker {
    let tracker = PushTracker(prefs: prefs)
    _ = tracker.next(first)
    return tracker
}

private func ids(_ requests: [BridgePending]) -> [String] { requests.map(\.requestId) }
private func ids(_ results: [(BridgeSession, PetState)]) -> [String] { results.map { "\($0.0.id):\($0.1.rawValue)" } }
private func ids(_ sessions: [BridgeSession]) -> [String] { sessions.map(\.id) }

// MARK: - What the Mac adds to Android's rules

/// Review focus 5: a Mac that has just started, or just had push set up, or a device that has just registered,
/// pushes nothing for what already was.
@Test func firstSnapshotOnlyRecords() {
    let tracker = PushTracker(prefs: both)
    let first = tracker.next(body(
        [session("a", .waiting), session("b", .waiting), session("c", .done), session("d", .error)],
        [pending("r1", "a")]
    ))
    #expect(first.isEmpty)
    #expect(first.post.isEmpty && first.withdraw.isEmpty && first.results.isEmpty)
    #expect(first.waitingNotices.isEmpty && first.withdrawWaiting.isEmpty && first.withdrawResults.isEmpty)
    // What it recorded is not news later: the request is still there, the waiting session is still waiting.
    let same = tracker.next(body(
        [session("a", .waiting), session("b", .waiting), session("c", .done), session("d", .error)],
        [pending("r1", "a")]
    ))
    #expect(same.isEmpty)
}

/// Review focus 5: three snapshots with the same request push it once.
@Test func aRequestIsPushedOnce() {
    let tracker = tracker(after: body([session("a")]))
    let asking = body([session("a", .waiting)], [pending("r1", "a")])
    #expect(ids(tracker.next(asking).post) == ["r1"])
    #expect(tracker.next(asking).post.isEmpty)
    #expect(tracker.next(asking).post.isEmpty)
    // A second request on the same session is news; the first is not.
    let more = tracker.next(body([session("a", .waiting)], [pending("r1", "a"), pending("r2", "a")]))
    #expect(ids(more.post) == ["r2"])
}

@Test func twoNewRequestsAreBothPushedInOrder() {
    let tracker = tracker(after: body([session("a"), session("b")]))
    let plan = tracker.next(body(
        [session("a", .waiting), session("b", .waiting)], [pending("r1", "a"), pending("r2", "b")]
    ))
    #expect(ids(plan.post) == ["r1", "r2"])
    // Asking is not a "waiting with nothing to answer" and not a result.
    #expect(plan.waitingNotices.isEmpty && plan.results.isEmpty)
}

@Test func aResolvedRequestIsWithdrawn() {
    let tracker = tracker(after: body([session("a", .waiting)], [pending("r1", "a"), pending("r2", "a")]))
    let plan = tracker.next(body([session("a", .waiting)], [pending("r2", "a")]))
    #expect(plan.withdraw == ["r1"])
    #expect(plan.post.isEmpty)
    // And once only.
    #expect(tracker.next(body([session("a", .waiting)], [pending("r2", "a")])).withdraw.isEmpty)
}

@Test func aRequestThatWasPushedIsWithdrawnWhenItsSessionEnds() {
    let tracker = tracker(after: body([session("a")]))
    _ = tracker.next(body([session("a", .waiting)], [pending("r1", "a")]))
    #expect(tracker.next(body([])).withdraw == ["r1"])
}

@Test func aRequestFromBeforeTheFirstSnapshotIsStillWithdrawnWhenItIsAnswered() {
    // Pushed by the Mac's previous run; it may well be on the phone's screen still.
    let tracker = tracker(after: body([session("a", .waiting)], [pending("r1", "a")]))
    #expect(tracker.next(body([session("a", .running)])).withdraw == ["r1"])
}

@Test func doneAndErrorFollowThePrefs() {
    let before = body([session("a", .running), session("b", .running)])
    let after = body([session("a", .done), session("b", .error)])

    #expect(tracker(off, after: before).next(after).results.isEmpty)

    let doneOnly = tracker(PushPrefs(notifyDone: true), after: before).next(after)
    #expect(ids(doneOnly.results) == ["a:done"])

    let errorOnly = tracker(PushPrefs(notifyError: true), after: before).next(after)
    #expect(ids(errorOnly.results) == ["b:error"])

    let bothOn = tracker(both, after: before).next(after)
    #expect(ids(bothOn.results) == ["a:done", "b:error"])
}

@Test func thePrefsCanChangeBetweenSnapshots() {
    let tracker = tracker(off, after: body([session("a", .running)]))
    tracker.prefs = PushPrefs(notifyDone: true)
    #expect(ids(tracker.next(body([session("a", .done)])).results) == ["a:done"])
}

@Test func waitingWithNothingToAnswerOnThePhoneGetsANotice() {
    // A VS Code session: `ask` is terminal-only, so it waits with no request.
    var vscode = session("a", .waiting)
    vscode.source = .vscode
    let tracker = tracker(after: body([session("a", .running)]))
    let plan = tracker.next(body([vscode]))
    #expect(ids(plan.waitingNotices) == ["a"])
    #expect(plan.post.isEmpty)
    // Once.
    #expect(tracker.next(body([vscode])).waitingNotices.isEmpty)
}

@Test func aSessionThatEndsWithdrawsItsNotices() {
    let prefs = both
    let tracker = tracker(prefs, after: body([session("a", .running), session("b", .running), session("c", .running)]))
    let plan = tracker.next(body([session("a", .waiting), session("b", .done), session("c", .error)]))
    #expect(ids(plan.waitingNotices) == ["a"])
    #expect(ids(plan.results) == ["b:done", "c:error"])

    let ended = tracker.next(body([]))
    #expect(ended.withdrawWaiting == ["waitingElsewhere:a"])
    #expect(ended.withdrawResults == ["done:b", "error:c"])
    #expect(ended.post.isEmpty && ended.waitingNotices.isEmpty && ended.results.isEmpty)
}

// MARK: - AlertPlannerTest.kt

@Test func staysQuietForAlreadyWaitingSessions() {
    let waiting = body([session("a", .waiting)], [pending("r1", "a")])
    let tracker = tracker(after: waiting)
    #expect(tracker.next(waiting).isEmpty)
}

@Test func doesNotRepeatAnUnchangedDoneState() {
    let done = body([session("a", .done)])
    let tracker = tracker(PushPrefs(notifyDone: true), after: done)
    #expect(tracker.next(done).results.isEmpty)
}

/// Not reposted when the same snapshot comes again (a reconnecting phone, a Mac that re-reads its state);
/// withdrawn when it is answered while nobody listened.
@Test func trackerDoesNotRepostAndWithdrawsWhatWasResolvedMeanwhile() {
    let a = body([session("a", .waiting)], [pending("r1", "a")])
    let tracker = tracker(after: body([session("a")]))
    #expect(ids(tracker.next(a).post) == ["r1"])
    #expect(tracker.next(a).isEmpty)

    let more = tracker.next(body([session("a", .waiting)], [pending("r1", "a"), pending("r2", "a")]))
    #expect(ids(more.post) == ["r2"])

    let resolved = tracker.next(body([session("a", .waiting)], [pending("r2", "a")]))
    #expect(resolved.withdraw == ["r1"])
    #expect(resolved.post.isEmpty)
}

@Test func waitingWithoutARequestGetsANoticeOncePerSpell() {
    let tracker = tracker(after: body([session("a", .running)]))
    #expect(ids(tracker.next(body([session("a", .waiting)])).waitingNotices) == ["a"])
    #expect(tracker.next(body([session("a", .waiting)])).waitingNotices.isEmpty)
    // Withdrawn once the session moves on.
    let moved = tracker.next(body([session("a", .running)]))
    #expect(moved.withdrawWaiting == ["waitingElsewhere:a"])
    // A new waiting spell is noticed again.
    #expect(ids(tracker.next(body([session("a", .waiting)])).waitingNotices) == ["a"])
}

@Test func waitingNoticeGivesWayToARequestAndDoesNotReturnAfterTheAnswer() {
    let tracker = tracker(after: body([session("a", .running)]))
    #expect(ids(tracker.next(body([session("a", .waiting)])).waitingNotices) == ["a"])
    // The request shows up a snapshot later: the notice goes, the request is pushed.
    let asked = tracker.next(body([session("a", .waiting)], [pending("r1", "a")]))
    #expect(asked.withdrawWaiting == ["waitingElsewhere:a"])
    #expect(ids(asked.post) == ["r1"])
    // Answered on the phone; the session stays "waiting" until the tool finishes. No "go to the computer".
    let answered = tracker.next(body([session("a", .waiting)]))
    #expect(answered.waitingNotices.isEmpty)
    #expect(answered.withdraw == ["r1"])
    _ = tracker.next(body([session("a", .running)]))
    #expect(ids(tracker.next(body([session("a", .waiting)])).waitingNotices) == ["a"])
}

@Test func waitingNoticeIsWithdrawnWhenTheSessionEnds() {
    let tracker = tracker(after: body([session("a", .running)]))
    _ = tracker.next(body([session("a", .waiting)]))
    #expect(tracker.next(body([])).withdrawWaiting == ["waitingElsewhere:a"])
}

@Test func resultNotificationIsWithdrawnWhenTheSessionLeavesDone() {
    let tracker = tracker(both, after: body([session("a", .running), session("b", .running)]))
    let finished = tracker.next(body([session("a", .done), session("b", .error)]))
    #expect(Set(ids(finished.results)) == ["a:done", "b:error"])
    #expect(finished.withdrawResults.isEmpty)
    // `a` was looked at on the Mac (idle); `b` is still an error.
    let seen = tracker.next(body([session("a", .idle), session("b", .error)]))
    #expect(seen.withdrawResults == ["done:a"])
    #expect(tracker.next(body([])).withdrawResults == ["error:b"])
}

@Test func aSessionThatTurnsFromDoneToErrorReplacesItsOldResult() {
    let tracker = tracker(both, after: body([session("a", .running)]))
    _ = tracker.next(body([session("a", .done)]))
    let failed = tracker.next(body([session("a", .error)]))
    #expect(ids(failed.results) == ["a:error"])
    // The finished notification would otherwise sit next to the failure.
    #expect(failed.withdrawResults == ["done:a"])
    // Leaving the error state takes the failure down, and only that.
    #expect(tracker.next(body([session("a", .idle)])).withdrawResults == ["error:a"])
}

/// A session the phone has not seen before: only a state just entered is reported, not one it arrives in.
@Test func newSessionAlreadyDoneDoesNotAlert() {
    let previous = body([session("a", .running)])
    let current = body([session("a", .running), session("b", .done), session("c", .error)])
    #expect(tracker(both, after: previous).next(current).results.isEmpty)

    // A new session that arrives with a permission request is pushed as usual.
    let asking = body([session("a", .running), session("d", .waiting)], [pending("r1", "d")])
    let plan = tracker(both, after: previous).next(asking)
    #expect(ids(plan.post) == ["r1"])
    #expect(plan.waitingNotices.isEmpty)
}

@Test func resetForgetsEverythingAndTheNextSnapshotOnlyRecords() {
    let asking = body([session("a", .waiting)], [pending("r1", "a")])
    let tracker = tracker(both, after: body([session("a", .running)]))
    #expect(ids(tracker.next(asking).post) == ["r1"])

    tracker.reset()
    // What exists after the reset is the past again: not pushed...
    #expect(tracker.next(asking).isEmpty)
    // ...and nothing else leaked through: it is not withdrawn either until it is gone.
    #expect(tracker.next(body([session("a", .running)])).withdraw == ["r1"])
}

@Test func resetAlsoForgetsWhatWasAboutToBeWithdrawn() {
    let tracker = tracker(both, after: body([session("a", .running)]))
    _ = tracker.next(body([session("a", .done)]))
    tracker.reset()
    // The first snapshot after the reset only records; the next shows the old `done` entry went with the reset.
    #expect(tracker.next(body([session("a", .idle)])).isEmpty)
    #expect(tracker.next(body([session("a", .idle)])).isEmpty)
}
