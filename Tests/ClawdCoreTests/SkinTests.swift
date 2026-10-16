import CoreGraphics
import Foundation
import Testing
@testable import ClawdCore

@Test func builtinMatchesSpecGrid() {
    #expect(SkinLoader.builtin().frames["base"] == [
        "...############...",
        "...##o######o##...",
        ".################.",
        "...############...",
        "....#.#....#.#....",
    ])
    #expect(SkinValidator.problems(SkinLoader.builtin()).isEmpty)
}

@Test func bundledFileEqualsBuiltin() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Skins/clawd/manifest.json").standardized
    #expect(try JSONDecoder().decode(SkinManifest.self, from: Data(contentsOf: url)) == SkinLoader.builtin())
}

@Test func validatorCatchesMissingStateAnimation() {
    var m = SkinLoader.builtin()
    m.animations.removeValue(forKey: "waiting")
    #expect(!SkinValidator.problems(m).isEmpty)
}

@Test func validatorCatchesMissingReferencedFrame() {
    var m = SkinLoader.builtin()
    m.animations["idle"] = AnimationSpec(frames: ["nope"], fps: 2, motion: .none)
    #expect(!SkinValidator.problems(m).isEmpty)
}

@Test func validatorCatchesInconsistentFrameWidth() {
    var m = SkinLoader.builtin()
    m.frames["base"] = ["...", "....."]
    #expect(!SkinValidator.problems(m).isEmpty)
}

@Test func validatorCatchesInconsistentFrameRowCount() {
    var m = SkinLoader.builtin()
    m.frames["blink"] = ["...............one line removed.."]
    #expect(!SkinValidator.problems(m).isEmpty)
}

@Test func validatorCatchesMissingPaletteCharacter() {
    var m = SkinLoader.builtin()
    m.palette.removeValue(forKey: "o")
    #expect(!SkinValidator.problems(m).isEmpty)
}

@Test func validatorCatchesNonPositiveFps() {
    var m = SkinLoader.builtin()
    m.animations["idle"] = AnimationSpec(frames: ["base"], fps: 0, motion: .none)
    #expect(!SkinValidator.problems(m).isEmpty)
}

@Test func loaderFallsBackOnInvalidSkin() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clawd-skin-tests-\(UUID().uuidString)")
    let skinDir = dir.appendingPathComponent("broken")
    try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)

    var invalid = SkinLoader.builtin()
    invalid.animations.removeValue(forKey: "waiting")
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
    invalid.animations.removeValue(forKey: "done")
    try JSONEncoder().encode(invalid).write(to: firstDir.appendingPathComponent("clawd/manifest.json"))

    var valid = SkinLoader.builtin()
    valid.name = "second-wins"
    try JSONEncoder().encode(valid).write(to: secondDir.appendingPathComponent("clawd/manifest.json"))

    let loaded = SkinLoader.load(name: "clawd", searchDirs: [firstDir, secondDir])
    #expect(loaded.name == "second-wins")
}

@Test func rendererProducesGridSizedImage() {
    let builtin = SkinLoader.builtin()
    let img = SkinRenderer.image(frame: builtin.frames["base"]!, palette: builtin.palette, dim: false)
    #expect(img?.width == 18)
    #expect(img?.height == 5)
}

@Test func rendererTransparentForDotsOpaqueForPaletteChars() {
    let frame = [".#", "#."]
    let palette = ["#": "#D97757"]
    let img = SkinRenderer.image(frame: frame, palette: palette, dim: false)
    #expect(img?.width == 2)
    #expect(img?.height == 2)
    #expect(img?.alphaInfo == .last || img?.alphaInfo == .premultipliedLast)
}
