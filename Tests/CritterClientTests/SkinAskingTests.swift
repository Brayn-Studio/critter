import CritterKit
import Testing
@testable import CritterClient

/// The phone has sprig (bundled) and nothing else.
private func missing(_ name: String) -> Bool { name != "sprig" }

/// A skin the Mac could not send (it answered nil, or a broken manifest) is not asked for again with the next
/// snapshot: once per connection, as on Android.
@Test func aMissingSkinIsAskedForOncePerConnection() {
    var asking = SkinAsking()
    let first = asking.toAsk(["custom", "sprig", "custom", "other"], live: true, missing: missing)
    #expect(first == ["custom", "other"])
    // The next snapshots, the request having failed: nothing again.
    let second = asking.toAsk(["custom", "other"], live: true, missing: missing)
    #expect(second.isEmpty)
    let third = asking.toAsk(["custom", "new"], live: true, missing: missing)
    #expect(third == ["new"])
}

/// The connection dropped: nothing is asked while not live, and the next connection asks again.
@Test func theNextConnectionAsksAgain() {
    var asking = SkinAsking()
    _ = asking.toAsk(["custom"], live: true, missing: missing)
    let offline = asking.toAsk(["custom"], live: false, missing: missing)
    #expect(offline.isEmpty)
    #expect(asking.asked.isEmpty)
    let again = asking.toAsk(["custom"], live: true, missing: missing)
    #expect(again == ["custom"])
}

/// A cached snapshot at launch is not live: nothing is asked (and so nothing is wrongly remembered as asked for the
/// connection that follows).
@Test func aCachedSnapshotAsksForNothing() {
    var asking = SkinAsking()
    let cached = asking.toAsk(["custom"], live: false, missing: missing)
    #expect(cached.isEmpty)
    let live = asking.toAsk(["custom"], live: true, missing: missing)
    #expect(live == ["custom"])
}

/// A skin the phone has (bundled, or sent before) is never asked for.
@Test func aSkinThePhoneHasIsNotAskedFor() {
    var asking = SkinAsking()
    let asked = asking.toAsk(["sprig"], live: true, missing: missing)
    #expect(asked.isEmpty)
}

/// Every session's skin, and the Mac's own, which runs the clock.
@Test func aSnapshotWearsItsSessionsSkinsAndTheMacs() {
    var a = fixtureSession("a")
    a.skin = "mochi"
    var body = fixtureBody([a, fixtureSession("b")])
    body.prefs.skin = "custom"
    #expect(SkinAsking.names(in: body) == ["mochi", "sprig", "custom"])
    #expect(SkinAsking.names(in: nil).isEmpty)
}
