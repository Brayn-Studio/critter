import CritterKit
import Foundation
import Testing
@testable import CritterClient

/// The repo's `Skins/` folder, found from this file: Tests/CritterClientTests/ -> repo root.
private let skinsDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Skins")

/// A bundled skin, read from the repo (what the app reads from its bundle).
private func bundled(_ name: String) -> SkinManifest? {
    SkinLoader.find(name: name, searchDirs: [skinsDir])
}

private func json(_ manifest: SkinManifest) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try! encoder.encode(manifest)
}

private func named(_ name: String, tickMs: Int? = nil, title: String? = nil) -> SkinManifest {
    var manifest = SkinLoader.builtin()
    manifest.name = name
    if let tickMs { manifest.tickMs = tickMs }
    if let title { manifest.title = title }
    return manifest
}

private let custom = json(named("custom"))
private let newcomer = json(named("newcomer"))

/// A new library is built whenever a skin arrives from the Mac (or the clock or forced skin changes). A manifest
/// whose source has not changed is taken over from the library before it, not decoded again (`loads` counts what
/// a library read or decoded itself).
@Test func rebuiltLibraryKeepsUnchangedManifests() {
    let lib1 = PhoneSkinLibrary(bundled: bundled, pushed: ["custom": custom], forced: nil, clockSkin: "sprig", reuse: nil)
    let sprig = lib1.manifest("sprig")
    let pushed = lib1.manifest("custom")

    let lib2 = PhoneSkinLibrary(
        bundled: bundled, pushed: ["custom": custom, "newcomer": newcomer], forced: nil, clockSkin: "sprig", reuse: lib1)
    #expect(lib2.manifest("sprig") == sprig)
    #expect(lib2.manifest("custom") == pushed)
    #expect(lib2.manifest("newcomer").name == "newcomer")
    #expect(lib2.loads == 1, "bundled and unchanged pushed taken over; only the newcomer decoded")

    // Taken over again by the library after that, even what lib2 itself only decoded.
    let lib3 = PhoneSkinLibrary(
        bundled: bundled, pushed: ["custom": custom, "newcomer": newcomer], forced: nil, clockSkin: "sprig", reuse: lib2)
    #expect(lib3.manifest("sprig") == sprig)
    #expect(lib3.manifest("newcomer") == lib2.manifest("newcomer"))
    #expect(lib3.manifest("custom") == pushed)
    #expect(lib3.loads == 0)
}

@Test func aChangedPushedManifestIsANewObject() {
    let lib1 = PhoneSkinLibrary(bundled: bundled, pushed: ["custom": custom], forced: nil, clockSkin: nil, reuse: nil)
    let before = lib1.manifest("custom")
    let changed = json(named("custom", title: "新的"))
    let lib2 = PhoneSkinLibrary(bundled: bundled, pushed: ["custom": changed], forced: nil, clockSkin: nil, reuse: lib1)
    #expect(lib2.manifest("custom") != before)
    #expect(lib2.manifest("custom").title == "新的")
    #expect(lib2.loads == 1)
}

/// A new clock skin on another tick: the row's skins are drawn as it now, not as they were.
@Test func aNewClockSkinIsNotTakenOver() {
    let slow = json(named("slow", tickMs: 100))
    let lib1 = PhoneSkinLibrary(bundled: bundled, pushed: ["slow": slow], forced: nil, clockSkin: "sprig", reuse: nil)
    let sprig = lib1.manifest("sprig")
    let lib2 = PhoneSkinLibrary(bundled: bundled, pushed: ["slow": slow], forced: nil, clockSkin: "slow", reuse: lib1)
    #expect(lib2.manifest("sprig") != sprig)
    #expect(lib2.manifest("sprig").name == "slow")
    // Back on the 60 ms clock, sprig is the very manifest it was.
    let lib3 = PhoneSkinLibrary(bundled: bundled, pushed: ["slow": slow], forced: nil, clockSkin: "mochi", reuse: lib2)
    #expect(lib3.manifest("sprig") == sprig)
    #expect(lib3.manifest("sprig").name == "sprig")
}

@Test func unknownSkinShowsSprigUntilTheMacSendsIt() {
    let before = PhoneSkinLibrary(bundled: bundled, pushed: [:], forced: nil, clockSkin: nil, reuse: nil)
    #expect(before.manifest("custom").name == "sprig")
    #expect(before.needsFetch("custom"))

    let after = PhoneSkinLibrary(bundled: bundled, pushed: ["custom": custom], forced: nil, clockSkin: nil, reuse: before)
    #expect(after.manifest("custom").name == "custom")
    #expect(!after.needsFetch("custom"))
    // What the app ships is never fetched.
    #expect(!after.needsFetch("sprig"))
    #expect(!after.needsFetch("mochi"))
}

@Test func aBrokenPushedSkinStaysSprig() {
    let library = PhoneSkinLibrary(
        bundled: bundled, pushed: ["bad": Data("{".utf8)], forced: nil, clockSkin: nil, reuse: nil)
    #expect(library.manifest("bad").name == "sprig")
    // Asking the Mac again would only bring the same thing.
    #expect(!library.needsFetch("bad"))
}

/// Valid JSON that is not a valid skin counts as broken too.
@Test func aPushedSkinThatFailsValidationStaysSprig() {
    var invalid = named("invalid")
    invalid.tickMs = 5
    let library = PhoneSkinLibrary(bundled: bundled, pushed: ["invalid": json(invalid)], forced: nil, clockSkin: nil, reuse: nil)
    #expect(library.manifest("invalid").name == "sprig")
}

@Test func pathLikeNamesAreNeverLookedUp() {
    var asked: [String] = []
    let library = PhoneSkinLibrary(
        bundled: { asked.append($0); return bundled($0) },
        pushed: ["../x": custom, "a/b": custom], forced: nil, clockSkin: nil, reuse: nil)
    for name in ["../x", "a/b", "a\\b", "x.y", ""] {
        #expect(library.manifest(name).name == "sprig", "\(name)")
        #expect(!library.needsFetch(name), "\(name)")
    }
    // Only the fallback itself is read.
    #expect(asked.allSatisfy { $0 == "sprig" }, "\(asked)")
}

@Test func theForcedSkinAnswersForEveryName() {
    let library = PhoneSkinLibrary(bundled: bundled, pushed: ["custom": custom], forced: "custom", clockSkin: "mochi", reuse: nil)
    #expect(library.manifest("sprig").name == "custom")
    #expect(library.manifest("anything").name == "custom")
    // An invalid forced skin falls back to sprig like any other.
    let missing = PhoneSkinLibrary(bundled: bundled, pushed: [:], forced: "nobody", clockSkin: nil, reuse: nil)
    #expect(missing.manifest("mochi").name == "sprig")
}

@Test func theLibraryNeverCrashesWithoutBundledSkins() {
    let library = PhoneSkinLibrary(bundled: { _ in nil }, pushed: [:], forced: nil, clockSkin: "sprig", reuse: nil)
    #expect(library.manifest("mochi").name == PhoneSkinLibrary.fallback)
}

/// The settings show the bundled skins sprig first, in the design's order, then any other by name.
@Test func skinsAreOrderedForTheSettings() {
    #expect(
        PhoneSkinLibrary.ordered(["bonnet", "zebra", "mochi", "sprig", "apple", "peep"])
            == ["sprig", "mochi", "peep", "bonnet", "apple", "zebra"]
    )
    #expect(PhoneSkinLibrary.ordered([]).isEmpty)
    #expect(PhoneSkinLibrary.ordered(PhoneSkinLibrary.preferredOrder.reversed()) == PhoneSkinLibrary.preferredOrder)
}
