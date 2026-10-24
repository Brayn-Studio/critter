import CryptoKit
import Foundation
import Testing
@testable import CritterCore

// The settings' APNs setup on disk: `~/.critter/bridge/apns/` (0700) holds `config.json` and the `.p8` (0600).
// Every test works in a temporary CRITTER_HOME, never the real one.

private func tempPaths() -> (CritterPaths, URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("critter-apns-tests-\(UUID().uuidString)")
    let paths = CritterPaths(critterHome: base.appendingPathComponent(".critter"), claudeHome: base.appendingPathComponent(".claude"))
    return (paths, base)
}

private func permissions(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}

/// A `.p8` as Apple hands it out: a P-256 private key in PKCS #8 PEM, saved world-readable in Downloads.
private func writeKey(named name: String, in dir: URL) throws -> (URL, String) {
    let pem = P256.Signing.PrivateKey().pemRepresentation
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data(pem.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    return (url, pem)
}

@Test func theSetupLivesUnderTheBridgeDirectory() {
    let paths = CritterPaths(critterHome: URL(fileURLWithPath: "/tmp/x/.critter"), claudeHome: URL(fileURLWithPath: "/tmp/x/.claude"))
    #expect(paths.apnsDir.path == "/tmp/x/.critter/bridge/apns")
    #expect(APNsConfigStore(paths: paths).configFile.path == "/tmp/x/.critter/bridge/apns/config.json")
}

@Test func importCopiesWithPrivatePermissions() throws {
    let (paths, base) = tempPaths()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = APNsConfigStore(paths: paths)
    let downloads = base.appendingPathComponent("Downloads")

    let (first, _) = try writeKey(named: "AuthKey_OLD0000000.p8", in: downloads)
    _ = try store.importKey(from: first)
    let (source, pem) = try writeKey(named: "AuthKey_ABC123DEFG.p8", in: downloads)
    let imported = try store.importKey(from: source)

    #expect(imported.keyFile == paths.apnsDir.appendingPathComponent("AuthKey_ABC123DEFG.p8"))
    #expect(try String(contentsOf: imported.keyFile, encoding: .utf8) == pem)
    #expect(permissions(imported.keyFile) == 0o600)
    #expect(permissions(paths.apnsDir) == 0o700)
    // The key it replaces is gone; the one in Downloads is the user's and stays.
    let left = try FileManager.default.contentsOfDirectory(atPath: paths.apnsDir.path).filter { $0.hasSuffix(".p8") }
    #expect(left == ["AuthKey_ABC123DEFG.p8"])
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(FileManager.default.fileExists(atPath: first.path))
}

@Test func keyIdIsReadFromTheFileName() throws {
    let (paths, base) = tempPaths()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = APNsConfigStore(paths: paths)
    let downloads = base.appendingPathComponent("Downloads")

    let (apple, _) = try writeKey(named: "AuthKey_ABC123DEFG.p8", in: downloads)
    #expect(try store.importKey(from: apple).keyId == "ABC123DEFG")

    // Renamed by the user: no Key ID to read, they type it; the copy gets a plain name.
    let (renamed, _) = try writeKey(named: "critter push.p8", in: downloads)
    let imported = try store.importKey(from: renamed)
    #expect(imported.keyId == nil)
    #expect(imported.keyFile.lastPathComponent == APNsConfigStore.unnamedKeyFile)
}

@Test func aFileThatIsNotAKeyIsRefusedAndNothingIsReplaced() throws {
    let (paths, base) = tempPaths()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = APNsConfigStore(paths: paths)
    let downloads = base.appendingPathComponent("Downloads")
    let (good, _) = try writeKey(named: "AuthKey_ABC123DEFG.p8", in: downloads)
    _ = try store.importKey(from: good)

    let junk = downloads.appendingPathComponent("AuthKey_JUNK000000.p8")
    try Data("not a key".utf8).write(to: junk)
    #expect(throws: APNsConfigStore.Failure.unreadableKey) { try store.importKey(from: junk) }
    #expect(throws: APNsConfigStore.Failure.unreadableKey) {
        try store.importKey(from: downloads.appendingPathComponent("AuthKey_GONE000000.p8"))
    }
    let left = try FileManager.default.contentsOfDirectory(atPath: paths.apnsDir.path).filter { $0.hasSuffix(".p8") }
    #expect(left == ["AuthKey_ABC123DEFG.p8"])
}

@Test func configRoundTrips() throws {
    let (paths, base) = tempPaths()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = APNsConfigStore(paths: paths)
    let (source, pem) = try writeKey(named: "AuthKey_ABC123DEFG.p8", in: base.appendingPathComponent("Downloads"))
    let imported = try store.importKey(from: source)

    let config = APNsConfig(keyId: "ABC123DEFG", teamId: "TEAM123456", bundleId: "com.example.critter", keyFile: imported.keyFile)
    try store.save(config)
    #expect(permissions(store.configFile) == 0o600)
    #expect(store.saved() == config)
    #expect(store.load() == .ready(config, pem: pem))
    // A new store over the same directory reads the same.
    #expect(APNsConfigStore(paths: paths).load() == .ready(config, pem: pem))

    // Only the key's name is kept: the setup stays inside the directory.
    let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.configFile)) as? [String: String])
    #expect(json == ["keyId": "ABC123DEFG", "teamId": "TEAM123456", "bundleId": "com.example.critter", "keyFile": "AuthKey_ABC123DEFG.p8"])
}

@Test func aMissingKeyFileIsReported() throws {
    let (paths, base) = tempPaths()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = APNsConfigStore(paths: paths)
    let missing = paths.apnsDir.appendingPathComponent("AuthKey_ABC123DEFG.p8")
    try store.save(APNsConfig(keyId: "ABC123DEFG", teamId: "TEAM123456", keyFile: missing))
    #expect(store.load() == .problem("读不了 .p8 文件"))

    // There, but not a key.
    try Data("garbage".utf8).write(to: missing)
    #expect(store.load() == .problem("读不了 .p8 文件"))
}

@Test func nothingSavedOrHalfFilledInIsNotConfigured() throws {
    let (paths, base) = tempPaths()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = APNsConfigStore(paths: paths)
    #expect(store.load() == .notConfigured)
    #expect(store.saved() == nil)
    // Reading does not make the directory.
    #expect(!FileManager.default.fileExists(atPath: paths.apnsDir.path))

    let (source, _) = try writeKey(named: "AuthKey_ABC123DEFG.p8", in: base.appendingPathComponent("Downloads"))
    let key = try store.importKey(from: source).keyFile
    for config in [
        APNsConfig(keyId: "ABC123DEFG", teamId: "", keyFile: key),
        APNsConfig(keyId: " ", teamId: "TEAM123456", keyFile: key),
        APNsConfig(keyId: "ABC123DEFG", teamId: "TEAM123456", bundleId: "", keyFile: key),
    ] {
        try store.save(config)
        #expect(store.load() == .notConfigured)
        #expect(store.saved() == config)
    }

    // A key file that is a path, not a name in the directory, is not read.
    try Data(#"{"keyId":"ABC123DEFG","teamId":"TEAM123456","bundleId":"b","keyFile":"../../AuthKey_ABC123DEFG.p8"}"#.utf8)
        .write(to: store.configFile)
    #expect(store.load() == .notConfigured)

    // A setup file that is not one.
    try Data("{".utf8).write(to: store.configFile)
    #expect(store.load() == .problem("读不了推送设置"))
}

@Test func aSetupWithoutAKeyYetKeepsItsFields() throws {
    let (paths, base) = tempPaths()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = APNsConfigStore(paths: paths)
    // The Team ID typed before a key was chosen.
    try store.save(APNsConfig(keyId: "", teamId: "TEAM123456", keyFile: store.directory))
    #expect(store.load() == .notConfigured)
    let saved = try #require(store.saved())
    #expect(saved.teamId == "TEAM123456")
    #expect(!store.hasKey(saved))
    // A key file somewhere else is not taken either: only one imported into the directory counts.
    try store.save(APNsConfig(keyId: "ABC123DEFG", teamId: "TEAM123456", keyFile: base.appendingPathComponent("AuthKey_ABC123DEFG.p8")))
    let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.configFile)) as? [String: String])
    #expect(json["keyFile"] == "")
    #expect(store.hasKey(APNsConfig(keyId: "", teamId: "", keyFile: store.directory.appendingPathComponent("AuthKey_X.p8"))))
}
