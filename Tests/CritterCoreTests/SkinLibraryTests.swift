import Foundation
import Testing
@testable import CritterCore

/// The repo's `Skins` folder, found from this file (as `bundledManifestIsTheDesignCopy` does).
let bundledSkinsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Skins").standardized

func bundledSkin(_ name: String) throws -> SkinManifest {
    try JSONDecoder().decode(SkinManifest.self, from: Data(contentsOf: bundledSkinsDir.appending(path: "\(name)/manifest.json")))
}

private func makeDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("critter-library-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ data: Data, in dir: URL, as name: String) throws {
    let skinDir = dir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
    try data.write(to: skinDir.appendingPathComponent("manifest.json"))
}

private func write(_ manifest: SkinManifest, in dir: URL, as name: String) throws {
    try write(JSONEncoder().encode(manifest), in: dir, as: name)
}

private func skin(_ name: String, title: String? = nil) -> SkinManifest {
    var m = SkinLoader.builtin()
    m.name = name
    m.title = title
    return m
}

private func invalidSkin(_ name: String, title: String? = nil) -> SkinManifest {
    var m = skin(name, title: title)
    m.states.removeValue(forKey: "waiting")
    return m
}

// MARK: - Choices

@Test func choiceTitleFallsBackToTheCapitalizedFolderName() {
    #expect(SkinChoice(name: "clawd", manifest: SkinLoader.builtin()).title == "Clawd")
    #expect(SkinChoice(name: "mine", manifest: skin("other")).title == "Mine")
    #expect(SkinChoice(name: "mine", manifest: skin("other", title: "小芽 Sprig")).title == "小芽 Sprig")
}

// MARK: - Library

@Test func libraryPutsTheBuiltinFirst() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try write(skin("sprig"), in: dir, as: "sprig")
    let missing = dir.appendingPathComponent("missing")

    let list = SkinLibrary.available(searchDirs: [missing, dir])
    #expect(list.map(\.name) == ["clawd", "sprig"])
    #expect(list[0].manifest == SkinLoader.builtin())
    #expect(list[0].title == "Clawd")
    #expect(SkinLibrary.available(searchDirs: []).map(\.name) == ["clawd"])
}

@Test func librarySkipsInvalidSkinsAndHiddenFolders() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try write(invalidSkin("broken"), in: dir, as: "broken")
    try write(Data("not json".utf8), in: dir, as: "garbage")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("empty"), withIntermediateDirectories: true)
    try Data().write(to: dir.appendingPathComponent("loose-file"))
    try write(skin("hidden"), in: dir, as: ".hidden")
    try write(skin("good"), in: dir, as: "good")

    #expect(SkinLibrary.available(searchDirs: [dir]).map(\.name) == ["clawd", "good"])
}

@Test func libraryNamesAChoiceByItsFolder() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try write(skin("other"), in: dir, as: "mine")
    try write(skin("other", title: "Titled"), in: dir, as: "theirs")

    let list = SkinLibrary.available(searchDirs: [dir])
    #expect(list.map(\.name) == ["clawd", "mine", "theirs"])
    #expect(list.map(\.title) == ["Clawd", "Mine", "Titled"])
    #expect(list[1].manifest.name == "other")
}

@Test func libraryFirstDirWins() throws {
    let first = try makeDir(), second = try makeDir()
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }
    try write(skin("custom", title: "First"), in: first, as: "custom")
    try write(skin("custom", title: "Second"), in: second, as: "custom")
    // Invalid in the first dir: taken from the second, as `SkinLoader.load` would.
    try write(invalidSkin("other", title: "First"), in: first, as: "other")
    try write(skin("other", title: "Second"), in: second, as: "other")

    let list = SkinLibrary.available(searchDirs: [first, second])
    #expect(list.map(\.name) == ["clawd", "custom", "other"])
    #expect(list.map(\.title) == ["Clawd", "First", "Second"])
}

@Test func libraryIgnoresCaseAcrossDirs() throws {
    // `~/.critter/skins/Sprig` is what loading "sprig" finds on the default (case-insensitive)
    // volume, so it shadows the bundled `sprig` and only one tile shows.
    let user = try makeDir(), bundled = try makeDir()
    defer {
        try? FileManager.default.removeItem(at: user)
        try? FileManager.default.removeItem(at: bundled)
    }
    try write(skin("sprig", title: "User"), in: user, as: "Sprig")
    try write(skin("sprig", title: "Bundled"), in: bundled, as: "sprig")
    try write(invalidSkin("mochi", title: "User"), in: user, as: "Mochi")
    try write(skin("mochi", title: "Bundled"), in: bundled, as: "mochi")
    try write(skin("clawd", title: "User"), in: user, as: "Clawd")

    let list = SkinLibrary.available(searchDirs: [user, bundled])
    #expect(list.map(\.name) == ["Clawd", "mochi", "Sprig"])
    #expect(list.map(\.title) == ["User", "Bundled", "User"])
}

@Test func libraryOnDiskClawdReplacesTheBuiltin() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try write(skin("clawd", title: "Custom Clawd"), in: dir, as: "clawd")

    let list = SkinLibrary.available(searchDirs: [dir])
    #expect(list.map(\.name) == ["clawd"])
    #expect(list[0].title == "Custom Clawd")
    #expect(list[0].manifest.title == "Custom Clawd")
}

@Test func librarySortsTheRestByName() throws {
    let first = try makeDir(), second = try makeDir()
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }
    try write(skin("zeta"), in: first, as: "zeta")
    try write(skin("alpha"), in: second, as: "alpha")
    try write(skin("mid"), in: first, as: "Mid")

    #expect(SkinLibrary.available(searchDirs: [first, second]).map(\.name) == ["clawd", "alpha", "Mid", "zeta"])
}

@Test func everyChoiceLoadsByItsName() throws {
    // Whatever tile is picked, the pet wears exactly what the tile shows.
    let user = try makeDir(), bundled = try makeDir()
    defer {
        try? FileManager.default.removeItem(at: user)
        try? FileManager.default.removeItem(at: bundled)
    }
    try write(skin("sprig", title: "User"), in: user, as: "Sprig")
    try write(invalidSkin("mochi", title: "User"), in: user, as: "mochi")
    try write(skin("other", title: "Mine"), in: user, as: "mine")
    try write(skin("sprig", title: "Bundled"), in: bundled, as: "sprig")
    try write(skin("mochi", title: "Bundled"), in: bundled, as: "mochi")
    try write(skin("peep", title: "Bundled"), in: bundled, as: "peep")

    for dirs in [[user, bundled], [bundled], [user]] {
        let list = SkinLibrary.available(searchDirs: dirs)
        #expect(list.count > 1)
        for choice in list {
            #expect(SkinLoader.load(name: choice.name, searchDirs: dirs) == choice.manifest, "\(choice.name)")
        }
    }

    // With an on-disk clawd standing in for the builtin too.
    try write(skin("clawd", title: "User"), in: user, as: "clawd")
    for choice in SkinLibrary.available(searchDirs: [user, bundled]) {
        #expect(SkinLoader.load(name: choice.name, searchDirs: [user, bundled]) == choice.manifest, "\(choice.name)")
    }
}

@Test func findHasNoFallback() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try write(invalidSkin("broken"), in: dir, as: "broken")
    try write(skin("good"), in: dir, as: "good")

    #expect(SkinLoader.find(name: "broken", searchDirs: [dir]) == nil)
    #expect(SkinLoader.find(name: "missing", searchDirs: [dir]) == nil)
    #expect(SkinLoader.find(name: "good", searchDirs: [dir])?.name == "good")
}

// MARK: - Bundled skins

@Test func everyBundledSkinIsValid() throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: bundledSkinsDir.path)
        .filter { !$0.hasPrefix(".") }
        .sorted()
    #expect(names.contains("clawd") && names.contains("sprig"))
    for name in names {
        let m = try bundledSkin(name)
        #expect(m.schema == 2, "\(name)")
        #expect(SkinValidator.problems(m) == [], "\(name)")
        #expect(m.name == name, "\(name)")
        if name != "clawd" {
            #expect(m.title != nil, "\(name) has no title")
        }
    }
    // The settings offer every one of them, the builtin first.
    #expect(SkinLibrary.available(searchDirs: [bundledSkinsDir]).map(\.name) == ["clawd"] + names.filter { $0 != "clawd" })
}
