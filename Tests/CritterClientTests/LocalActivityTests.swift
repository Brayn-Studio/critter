import CritterClient
import CritterCore
import CritterKit
import Foundation
import Testing

// What the app does to its own Live Activity (spec §8.5): it starts one in front, updates it while connected, ends it
// when switched off, and leaves it to the Mac's pushes in the background.

private let now: Int64 = 1_760_000_000_000

private func session(_ id: String, _ state: PetState, skin: String = "sprig", startedAt: Int64 = 1) -> BridgeSession {
    BridgeSession(
        id: id, name: "name \(id)", source: .terminal, state: state, detail: nil, activity: nil, cwd: "/p/\(id)",
        branch: nil, skin: skin, eventTime: 5, startedAt: startedAt, tracked: true
    )
}

private func snapshot(_ sessions: [BridgeSession], fiveHour: Double? = 40) -> SnapshotBody {
    SnapshotBody(
        sessions: sessions,
        limits: BridgeLimits(fiveHour: fiveHour.map { RateWindow(usedPercentage: $0, resetsAt: 9) }, sevenDay: nil, updatedAt: 1),
        pending: [],
        prefs: BridgePrefs(skin: "sprig", randomSkins: false, idleDim: 1.0, mergeThreshold: 4, soundTheme: "pixel")
    )
}

private let two = snapshot([session("a", .waiting, startedAt: 2), session("b", .running, skin: "mochi", startedAt: 1)])

private func step(
    enabled: Bool = true, inFront: Bool = true, live: Bool = true, _ snapshot: SnapshotBody? = two,
    shown: LiveActivityContent? = nil, at time: Int64 = now
) -> LocalActivityStep {
    LocalActivity.step(enabled: enabled, inFront: inFront, live: live, snapshot: snapshot, shown: shown, now: time)
}

/// The phone assembles the same content as the Mac for the same snapshot: one rule, in CritterKit.
@Test func thePhoneAndTheMacAssembleTheSameContent() {
    let snapshots = [
        two, snapshot([]), snapshot([session("a", .idle)], fiveHour: nil),
        snapshot([
            session("a", .done, skin: "peep", startedAt: 5), session("b", .running, startedAt: 1),
            session("c", .done, startedAt: 2), session("d", .error, skin: "bristle", startedAt: 9),
            session("e", .error, startedAt: 3), session("f", .waiting, skin: "frill", startedAt: 7),
        ], fiveHour: 85.5),
    ]
    for body in snapshots {
        let phone = LocalActivity.content(body, now: now)
        #expect(phone == LiveActivityPlanner().content(from: body, updatedAt: now))
        #expect(phone == LiveActivityContent(snapshot: body, updatedAt: now))
    }
}

@Test func theAppStartsItsOwnInFrontWhileConnectedWithSessions() {
    #expect(step() == .start(LocalActivity.content(two, now: now)))
}

@Test func nothingStartsWithoutSessionsSwitchedOffOrAway() {
    #expect(step(snapshot([])) == .none)
    #expect(step(nil) == .none)
    #expect(step(enabled: false) == .none)
    // In the background the Mac's pushes do it all.
    #expect(step(inFront: false) == .none)
    // Not connected (an old snapshot from before): the Mac could not learn the activity's token either.
    #expect(step(live: false) == .none)
}

@Test func anUnchangedContentIsNotUpdated() {
    // Shown since a minute ago: only the time it was made differs.
    let shown = LocalActivity.content(two, now: now - 60_000)
    #expect(step(shown: shown) == .none)
}

@Test func aChangedContentIsUpdatedInFrontWhileConnected() {
    let shown = LocalActivity.content(snapshot([session("a", .running)]), now: now - 60_000)
    #expect(step(shown: shown) == .update(LocalActivity.content(two, now: now)))
    // The limits alone count as a change too.
    let limits = LocalActivity.content(snapshot(two.sessions, fiveHour: 41), now: now - 60_000)
    #expect(step(shown: limits) == .update(LocalActivity.content(two, now: now)))
}

@Test func theBackgroundLeavesTheActivityToTheMac() {
    let shown = LocalActivity.content(snapshot([session("a", .running)]), now: now - 60_000)
    #expect(step(inFront: false, shown: shown) == .none)
    #expect(step(live: false, shown: shown) == .none)
}

@Test func switchingOffEndsTheActivityWhereverTheAppIs() {
    let shown = LocalActivity.content(two, now: now)
    #expect(step(enabled: false, shown: shown) == .endAll)
    #expect(step(enabled: false, inFront: false, live: false, nil, shown: shown) == .endAll)
}

@Test func aRunningOneShowsWhenTheLastSessionEnds() {
    // No sessions left: the activity says so (the Mac ends it five minutes later).
    let shown = LocalActivity.content(two, now: now - 60_000)
    #expect(step(snapshot([]), shown: shown) == .update(LocalActivity.content(snapshot([]), now: now)))
}

@Test func twoContentsAreTheSameButForTheirTime() {
    let a = LocalActivity.content(two, now: 1)
    #expect(LocalActivity.same(a, LocalActivity.content(two, now: 2)))
    #expect(!LocalActivity.same(a, LocalActivity.content(snapshot([session("a", .waiting)]), now: 1)))
}

// MARK: - Which one to keep

private func running(_ ids: [(String, Int64)]) -> [RunningActivity] {
    ids.map { RunningActivity(id: $0.0, seenAt: $0.1) }
}

/// More than one running (the Mac's push-to-start next to the app's own): the one the registration names stays;
/// before any is named, the app's own; otherwise the one seen last, and among those seen at once (at launch) the
/// smallest id.
@Test func theRegisteredOneIsKeptThenTheAppsOwnThenTheNewest() {
    let three = running([("A", 10), ("B", 20), ("C", 20)])
    #expect(LocalActivity.keeper(running: three, named: "A", own: "B") == "A")
    #expect(LocalActivity.keeper(running: three, named: nil, own: "A") == "A")
    // Named or own but no longer running: not kept.
    #expect(LocalActivity.keeper(running: three, named: "Z", own: "Y") == "B")
    #expect(LocalActivity.keeper(running: running([("C", 20), ("B", 20)]), named: nil, own: nil) == "B")
    #expect(LocalActivity.keeper(running: running([("A", 30), ("B", 20)]), named: nil, own: nil) == "A")
    #expect(LocalActivity.keeper(running: [], named: "A", own: "A") == nil)
}
