import CoreGraphics
import Foundation
import Testing
@testable import ClawdCore

// MARK: - Manifest and decoding

@Test func bundledManifestIsTheDesignCopy() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
    let bundled = try Data(contentsOf: root.appending(path: "Skins/clawd/manifest.json"))
    let design = try Data(contentsOf: root.appending(path: "docs/superpowers/specs/2026-10-17-clawd-manifest-v2.json"))
    #expect(bundled == design)
    #expect(String(decoding: bundled, as: UTF8.self) == SkinLoader.builtinJSON)
}

@Test func builtinIsValidSchema2() {
    let m = SkinLoader.builtin()
    #expect(m.schema == 2)
    #expect(m.tickMs == 60)
    #expect(m.grid == [18, 10])
    #expect(SkinValidator.problems(m).isEmpty)
}

@Test func builtinSurvivesEncodeDecodeRoundTrip() throws {
    let m = SkinLoader.builtin()
    let again = try JSONDecoder().decode(SkinManifest.self, from: JSONEncoder().encode(m))
    #expect(again == m)
}

@Test func clipKeyDecodesShortAndLongForms() throws {
    let json = #"[["base",40],["base",10,0,-1],["base",1,0,-2,"dust"]]"#
    let keys = try JSONDecoder().decode(MotionClip.self, from: Data(json.utf8))
    #expect(keys == [ClipKey(pose: "base", ticks: 40, dx: 0, dy: 0, effect: nil),
                     ClipKey(pose: "base", ticks: 10, dx: 0, dy: -1, effect: nil),
                     ClipKey(pose: "base", ticks: 1, dx: 0, dy: -2, effect: "dust")])
    #expect(String(decoding: try JSONEncoder().encode(keys), as: UTF8.self) == json)
}

@Test func clipKeyEncodesEffectWithZeroOffsetInFiveElements() throws {
    let key = ClipKey(pose: "shut", ticks: 25, dx: 0, dy: 0, effect: "zzz")
    #expect(String(decoding: try JSONEncoder().encode(key), as: UTF8.self) == #"["shut",25,0,0,"zzz"]"#)
}

@Test func clipKeyRejectsThreeElements() {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ClipKey.self, from: Data(#"["base",1,2]"#.utf8))
    }
}

@Test func spanDecodesNumberOrRange() throws {
    #expect(try JSONDecoder().decode(Span.self, from: Data("5".utf8)) == Span(5))
    #expect(try JSONDecoder().decode(Span.self, from: Data("[3,13]".utf8)) == Span(3, 13))
}

@Test func spanEncodesNumberWhenCollapsed() throws {
    #expect(String(decoding: try JSONEncoder().encode(Span(5)), as: UTF8.self) == "5")
    #expect(String(decoding: try JSONEncoder().encode(Span(3, 13)), as: UTF8.self) == "[3,13]")
}

@Test func weightedClipDecodesFromPair() throws {
    let w = try JSONDecoder().decode(WeightedClip.self, from: Data(#"["blink",6]"#.utf8))
    #expect(w == WeightedClip(clip: "blink", weight: 6))
}

// MARK: - Rasterization

@Test func basePoseIsTheApprovedGridDoubled() {
    let old = ["...############...", "...##o######o##...", ".################.", "...############...", "....#.#....#.#...."]
    let g = SkinRenderer.grid(pose: "base", in: SkinLoader.builtin())!
    for y in 0..<10 {
        for x in 0..<18 {
            let want = Array(old[y / 2])[x]
            #expect(g.character(atX: x, y: y) == (want == "." ? nil : want))
        }
    }
}

@Test func heldPoseHangsBelowGround() {   // dangling legs reach row 10
    let g = SkinRenderer.grid(pose: "held_a", in: SkinLoader.builtin())!
    #expect(g.minY + g.height == 11)
}

@Test func laterPartsCoverEarlierOnes() {
    let g = SkinRenderer.grid(pose: "base", in: SkinLoader.builtin())!
    #expect(g.character(atX: 5, y: 2) == "o")   // eyes over body
}

@Test func unknownPoseHasNoGrid() {
    #expect(SkinRenderer.grid(pose: "nope", in: SkinLoader.builtin()) == nil)
}

@Test func croppingKeepsTheBaseBox() {
    let skin = SkinLoader.builtin()
    let g = SkinRenderer.grid(pose: "held_a", in: skin)!.cropped(minX: 0, minY: 0, width: 18, height: 10)
    #expect(g.rows.count == 10)
    #expect(g.rows.allSatisfy { $0.count == 18 })
    #expect(g.character(atX: 5, y: 10) == nil)
}

private func rgba(_ image: CGImage?) -> [UInt8] {
    guard let data = image?.dataProvider?.data else { return [] }
    return Array((data as Data).prefix(4))
}

@Test func dimImageMixesHalfWithGrey() {
    let g = PixelGrid(minX: 0, minY: 0, width: 1, height: 1, rows: ["#"])
    let palette = ["#": "#D97757"]
    #expect(rgba(SkinRenderer.image(g, palette: palette, dim: true)) == [172, 123, 107, 217])
    #expect(rgba(SkinRenderer.image(g, palette: palette, dim: false)) == [217, 119, 87, 255])
}

@Test func imageIsGridSized() {
    let g = SkinRenderer.grid(pose: "base", in: SkinLoader.builtin())!
    let img = SkinRenderer.image(g, palette: SkinLoader.builtin().palette, dim: false)
    #expect(img?.width == g.width)
    #expect(img?.height == g.height)
}

@Test func glyphImageDrawsHashesOnly() {
    let img = SkinRenderer.glyphImage(["#."], color: "#34C759")
    #expect(img?.width == 2)
    #expect(rgba(img) == [0x34, 0xC7, 0x59, 255])
}

// MARK: - Validator

private func mutated(_ change: (inout SkinManifest) -> Void) -> [String] {
    var m = SkinLoader.builtin()
    change(&m)
    return SkinValidator.problems(m)
}

@Test func validatorRejectsSchema1() { #expect(!mutated { $0.schema = 1 }.isEmpty) }
@Test func validatorCatchesMissingState() { #expect(!mutated { $0.states.removeValue(forKey: "waiting") }.isEmpty) }
@Test func validatorCatchesUnknownPoseInClip() { #expect(!mutated { $0.clips["idle"] = [ClipKey(pose: "nope", ticks: 1)] }.isEmpty) }
@Test func validatorCatchesZeroTickKey() { #expect(!mutated { $0.clips["idle"] = [ClipKey(pose: "base", ticks: 0)] }.isEmpty) }
@Test func validatorCatchesUnknownEffect() { #expect(!mutated { $0.clips["idle"] = [ClipKey(pose: "base", ticks: 1, effect: "nope")] }.isEmpty) }
@Test func validatorReportsReservedEffectNameAsUnknown() {
    #expect(!mutated { $0.clips["idle"] = [ClipKey(pose: "base", ticks: 1, effect: "@seat")] }.isEmpty)
    #expect(!mutated { $0.effects["@seat"] = $0.effects["dust"] }.isEmpty)
}
@Test func validatorCatchesUnknownPartInPose() { #expect(!mutated { $0.poses["base"] = ["body", "nope"] }.isEmpty) }
@Test func validatorCatchesRaggedPartRows() { #expect(!mutated { $0.parts["body"]!.rows = ["####", "##"] }.isEmpty) }
@Test func validatorCatchesCharacterNotInPalette() { #expect(!mutated { $0.palette.removeValue(forKey: "o") }.isEmpty) }
@Test func validatorCatchesMissingVariantLoop() { #expect(!mutated { $0.states["running"]!.variants!["think"]!.loop = "nope" }.isEmpty) }
@Test func validatorCatchesUnknownInteractionClip() { #expect(!mutated { $0.interactions.notice = "nope" }.isEmpty) }
@Test func validatorCatchesUnknownGlyphInEffect() { #expect(!mutated { $0.effects["dust"]!.particles![0].glyph = "nope" }.isEmpty) }

// MARK: - Loader

@Test func loaderFallsBackOnInvalidSkin() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clawd-skin-tests-\(UUID().uuidString)")
    let skinDir = dir.appendingPathComponent("broken")
    try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)

    var invalid = SkinLoader.builtin()
    invalid.states.removeValue(forKey: "waiting")
    try JSONEncoder().encode(invalid).write(to: skinDir.appendingPathComponent("manifest.json"))

    let loaded = SkinLoader.load(name: "broken", searchDirs: [dir])
    #expect(loaded == SkinLoader.builtin())
}

@Test func loaderFindsValidSkinInSearchDirs() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clawd-skin-tests-\(UUID().uuidString)")
    let skinDir = dir.appendingPathComponent("custom")
    try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)

    var custom = SkinLoader.builtin()
    custom.name = "custom"
    try JSONEncoder().encode(custom).write(to: skinDir.appendingPathComponent("manifest.json"))

    let loaded = SkinLoader.load(name: "custom", searchDirs: [dir])
    #expect(loaded.name == "custom")
}

@Test func loaderFirstValidDirWins() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clawd-skin-tests-\(UUID().uuidString)")
    let firstDir = dir.appendingPathComponent("first")
    let secondDir = dir.appendingPathComponent("second")
    try FileManager.default.createDirectory(at: firstDir.appendingPathComponent("clawd"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondDir.appendingPathComponent("clawd"), withIntermediateDirectories: true)

    // The first search dir has an invalid skin, so the loader should fall through to the
    // second, valid one, rather than giving up and returning the builtin.
    var invalid = SkinLoader.builtin()
    invalid.states.removeValue(forKey: "waiting")
    try JSONEncoder().encode(invalid).write(to: firstDir.appendingPathComponent("clawd/manifest.json"))

    var valid = SkinLoader.builtin()
    valid.name = "second-wins"
    try JSONEncoder().encode(valid).write(to: secondDir.appendingPathComponent("clawd/manifest.json"))

    let loaded = SkinLoader.load(name: "clawd", searchDirs: [firstDir, secondDir])
    #expect(loaded.name == "second-wins")
}
