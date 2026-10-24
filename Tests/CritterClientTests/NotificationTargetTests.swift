import CritterClient
import CritterKit
import Testing

// What the home screen does with a tapped notification's target (spec §8.4).

private let live = fixtureBody([fixtureSession("a"), fixtureSession("b", state: .done)])

/// A request's card opens by its id at once: the card itself waits for a live snapshot before it says the request is
/// gone.
@Test func aRequestOpensItsCardAtOnce() {
    let target = NotificationTarget(.request("r1"), pairing: "d1")
    #expect(target.decision(pairing: "d1", snapshot: nil, isLive: false, waitedOut: false) == .openRequest("r1"))
    #expect(target.decision(pairing: "d1", snapshot: live, isLive: true, waitedOut: false) == .openRequest("r1"))
}

/// A session in the snapshot opens, cached or live.
@Test func aSessionInTheSnapshotOpens() {
    let target = NotificationTarget(.session("b"), pairing: "d1")
    #expect(target.decision(pairing: "d1", snapshot: live, isLive: false, waitedOut: false) == .openSession(fixtureSession("b", state: .done)))
    #expect(target.decision(pairing: "d1", snapshot: live, isLive: true, waitedOut: false) == .openSession(fixtureSession("b", state: .done)))
}

/// Cold launch: the cached snapshot is from before the session began. That proves nothing; it waits for a live one,
/// for as long as the sheets wait (`waitedOut`), and only a live snapshot without it (or the wait running out) drops it.
@Test func aSessionMissingFromACachedSnapshotWaitsForALiveOne() {
    let target = NotificationTarget(.session("new"), pairing: "d1")
    #expect(target.decision(pairing: "d1", snapshot: live, isLive: false, waitedOut: false) == .wait)
    #expect(target.decision(pairing: "d1", snapshot: nil, isLive: false, waitedOut: false) == .wait)
    #expect(target.decision(pairing: "d1", snapshot: live, isLive: true, waitedOut: false) == .drop)
    #expect(target.decision(pairing: "d1", snapshot: live, isLive: false, waitedOut: true) == .drop)
    #expect(target.decision(pairing: "d1", snapshot: nil, isLive: false, waitedOut: true) == .drop)
    // It came during the wait: opens.
    let later = fixtureBody([fixtureSession("new")])
    #expect(target.decision(pairing: "d1", snapshot: later, isLive: true, waitedOut: false) == .openSession(fixtureSession("new")))
}

/// Tapped while pairing again: once the new pairing is made, the target belongs to the Mac that was replaced, whose
/// requests and sessions the new one does not have (even under the same ids).
@Test func aTargetFromAnotherPairingIsDropped() {
    let request = NotificationTarget(.request("r1"), pairing: "d1")
    #expect(request.decision(pairing: "d2", snapshot: live, isLive: true, waitedOut: false) == .drop)
    #expect(!request.belongs(to: "d2"))
    #expect(request.belongs(to: "d1"))
    let session = NotificationTarget(.session("a"), pairing: "d1")
    #expect(session.decision(pairing: "d2", snapshot: live, isLive: true, waitedOut: false) == .drop)
    // Unpaired since.
    #expect(session.decision(pairing: nil, snapshot: nil, isLive: false, waitedOut: false) == .drop)
}
