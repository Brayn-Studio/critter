import CryptoKit
import Foundation

/// The settings' APNs setup on disk (spec 6.4): `~/.critter/bridge/apns/` (0700) holds the `.p8` key Apple gave
/// the user and `config.json` with the Key ID, Team ID, bundle id and the key's file name (all 0600). Nothing
/// of it goes to `UserDefaults`, the repository or the log.
///
/// Every call reads or writes the files there and then; callers keep it off the main thread.
public struct APNsConfigStore: Sendable {
    public enum Failure: Error, Equatable {
        /// The file could not be read, or is not a P-256 private key in PEM.
        case unreadableKey
    }

    /// What `importKey` stored.
    public struct ImportedKey: Equatable, Sendable {
        public var keyFile: URL
        /// From Apple's file name, `AuthKey_<KeyID>.p8`; nil when the file was renamed.
        public var keyId: String?
    }

    /// The name a key gets when its own does not carry the Key ID.
    public static let unnamedKeyFile = "AuthKey.p8"
    /// The status when `config.json` is there but cannot be read.
    public static let unreadableConfig = "读不了推送设置"

    public let directory: URL
    public var configFile: URL { directory.appendingPathComponent("config.json") }

    public init(paths: CritterPaths) {
        directory = paths.apnsDir
    }

    /// What `config.json` holds.
    private struct Stored: Codable {
        var keyId: String
        var teamId: String
        var bundleId: String
        /// A file name in `directory`, never a path.
        var keyFile: String
    }

    /// The setup as saved, filled in or not; nil when there is none (or it cannot be read).
    public func saved() -> APNsConfig? {
        stored().map(config)
    }

    /// What the setup amounts to: not there or not filled in, ready (with the key's PEM), or why it cannot work.
    public func load() -> APNsSetup {
        guard FileManager.default.fileExists(atPath: configFile.path) else { return .notConfigured }
        guard let stored = stored() else { return .problem(Self.unreadableConfig) }
        let filled = [stored.keyId, stored.teamId, stored.bundleId, stored.keyFile]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard filled else { return .notConfigured }
        let config = config(stored)
        guard let pem = Self.readKey(config.keyFile) else { return .problem(APNsSetup.unreadableKey) }
        return .ready(config, pem: pem)
    }

    /// `config.json`, with a key file that is a name in `directory` (anything else reads as none).
    private func stored() -> Stored? {
        guard let data = try? Data(contentsOf: configFile), var stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }
        if stored.keyFile.contains("/") || stored.keyFile.hasPrefix(".") { stored.keyFile = "" }
        return stored
    }

    private func config(_ stored: Stored) -> APNsConfig {
        APNsConfig(
            keyId: stored.keyId, teamId: stored.teamId, bundleId: stored.bundleId,
            keyFile: directory.appendingPathComponent(stored.keyFile)
        )
    }

    /// Whether `config`'s key file is one in `directory` (an imported key). A setup saved before any key was
    /// chosen has none; pass `directory` itself for "no key yet".
    public func hasKey(_ config: APNsConfig) -> Bool {
        config.keyFile.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path
            && !config.keyFile.lastPathComponent.isEmpty
    }

    /// Saves the setup. Only the key's file name is kept, and only for a key in `directory` (`hasKey`); without
    /// one the other fields are kept for when a key is chosen.
    public func save(_ config: APNsConfig) throws {
        try PrivateDirectory.ensure(directory)
        let stored = Stored(
            keyId: config.keyId, teamId: config.teamId, bundleId: config.bundleId,
            keyFile: hasKey(config) ? config.keyFile.lastPathComponent : ""
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try atomicWrite(encoder.encode(stored), to: configFile, permissions: 0o600)
    }

    /// Copies the `.p8` at `source` into `directory` (0600) as `AuthKey_<KeyID>.p8`, or `AuthKey.p8` when its
    /// name does not say the Key ID, and deletes any other `.p8` there. The file at `source` is left alone.
    /// Throws `unreadableKey`, replacing nothing, when it cannot be read or is not a key.
    public func importKey(from source: URL) throws -> ImportedKey {
        guard let pem = Self.readKey(source) else { throw Failure.unreadableKey }
        let keyId = APNsConfig.keyId(fromFileName: source.lastPathComponent)
        let name = keyId.map { "AuthKey_\($0).p8" } ?? Self.unnamedKeyFile
        try PrivateDirectory.ensure(directory)
        let keyFile = directory.appendingPathComponent(name)
        try atomicWrite(Data(pem.utf8), to: keyFile, permissions: 0o600)
        let others = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for other in others where other.hasSuffix(".p8") && other != name {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(other))
        }
        return ImportedKey(keyFile: keyFile, keyId: keyId)
    }

    /// The PEM at `url` when it is a P-256 private key; nil otherwise.
    private static func readKey(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), let pem = String(data: data, encoding: .utf8),
              (try? P256.Signing.PrivateKey(pemRepresentation: pem)) != nil
        else { return nil }
        return pem
    }
}
