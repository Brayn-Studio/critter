import Testing
@testable import CritterClient

/// What the real watcher fires on: a path that is usable, and not the one it saw last.
@Test func aPathFiresOnlyWhenItIsUsableAndNew() {
    var filter = PathChangeFilter<String>()
    func fires(_ satisfied: Bool, _ path: String) -> Bool {
        filter.shouldFire(satisfied: satisfied, path: path)
    }
    // The first usable path: the network is there, and the app has not seen it yet.
    #expect(fires(true, "wifi"))
    // The same path reported again (the system does this on any detail changing): nothing new.
    #expect(!fires(true, "wifi"))
    // Gone: not usable, nothing to connect to.
    #expect(!fires(false, "none"))
    // Back, on the same Wi-Fi as before: it is new against the last path seen, which was "none".
    #expect(fires(true, "wifi"))
    // Another network: new.
    #expect(fires(true, "cellular"))
    // A change to something unusable fires nothing, and the next usable path is new again.
    #expect(!fires(false, "cellular, no route"))
    #expect(fires(true, "cellular"))
}
