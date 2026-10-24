import CritterKit
import Foundation
import os

/// The phone's pairing and last snapshot (spec §8.1), as the app keeps them in its App Group: the pairing record
/// (address, port, fingerprint, the Mac's name, the device id) as a JSON file, its token in a `SecretStore` under the
/// device id (the shared keychain), and the last snapshot as a JSON file, stamped with the device id of the pairing it
/// came with.
///
/// - A new pairing's token goes in first. Only once it is in is the record replaced, the old snapshot deleted and the
///   old token removed; a token that cannot be written changes nothing, and `save` says so.
/// - A token is only ever read under the device id of the record, and a snapshot only for the pairing it was written
///   with: another Mac's never shows, even if the app was killed between writing a new pairing and deleting the old
///   snapshot.
/// - Snapshots are encoded and written on a private serial queue, since one can be over a megabyte and the caller is
///   the main actor. Deleting goes through the same queue and waits for it, so it is done when `save` or `clear`
///   returns, and a snapshot saved before is never written after. How often to save is the caller's business
///   (`BridgeStore` writes at most every 30 seconds).
/// - The snapshot holds commands, plan text, paths and the names of sessions and the Mac, so it stays out of iCloud and
///   computer backups (spec §3): its folder is marked excluded from backup, which covers the file however often an
///   atomic write replaces it.
public final class DiskPairingStorage: PairingStorage {
    private static let log = Logger(subsystem: "com.braynlabs.critter", category: "storage")

    private let tokens: any SecretStore
    private let pairingFile: URL
    private let snapshotFile: URL
    private let queue = DispatchQueue(label: "com.braynlabs.critter.snapshot", qos: .utility)

    /// The snapshot as it is written: whose it is, and the snapshot.
    private struct SnapshotFile: Codable {
        var deviceId: String
        var snapshot: CachedSnapshot
    }

    public init(tokens: any SecretStore, pairingFile: URL, snapshotFile: URL) {
        self.tokens = tokens
        self.pairingFile = pairingFile
        self.snapshotFile = snapshotFile
    }

    // MARK: - The pairing

    public func load() -> (StoredPairing, Credentials)? {
        guard let pairing = readPairing(), let token = tokens.secret(pairing.deviceId) else { return nil }
        return (pairing, Credentials(deviceId: pairing.deviceId, token: token))
    }

    public func save(_ pairing: StoredPairing, token: String) -> Bool {
        guard tokens.setSecret(token, for: pairing.deviceId) else {
            Self.log.error("saving the token failed: the old pairing stays")
            return false
        }
        guard writePairing(pairing) else {
            // The old record stays, and with it the old token; the new one goes.
            if readPairing()?.deviceId != pairing.deviceId { tokens.removeSecret(pairing.deviceId) }
            return false
        }
        dropSnapshot()
        tokens.removeSecrets(keeping: pairing.deviceId)
        return true
    }

    public func updateEndpoint(_ endpoint: Endpoint) {
        guard var pairing = readPairing() else { return }
        pairing.endpoint = endpoint
        writePairing(pairing)
    }

    /// The record first: stopped halfway, the phone is unpaired, never paired with half a pairing.
    public func clear() {
        do {
            try FileManager.default.removeItem(at: pairingFile)
        } catch CocoaError.fileNoSuchFile {
        } catch {
            Self.log.error("deleting the pairing failed: \(error)")
        }
        tokens.removeSecrets(keeping: nil)
        dropSnapshot()
    }

    private func readPairing() -> StoredPairing? {
        guard let data = try? Data(contentsOf: pairingFile) else { return nil }
        return try? JSONDecoder().decode(StoredPairing.self, from: data)
    }

    @discardableResult
    private func writePairing(_ pairing: StoredPairing) -> Bool {
        do {
            let data = try JSONEncoder().encode(pairing)
            try FileManager.default.createDirectory(at: pairingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: pairingFile, options: .atomic)
            return true
        } catch {
            Self.log.error("writing the pairing failed: \(error)")
            return false
        }
    }

    // MARK: - The snapshot

    /// Read at launch, on the caller's thread: the stored pairing's snapshot, nil if the file is another pairing's.
    public func loadSnapshot() -> CachedSnapshot? {
        guard let deviceId = readPairing()?.deviceId, let data = try? Data(contentsOf: snapshotFile),
              let file = try? JSONDecoder().decode(SnapshotFile.self, from: data), file.deviceId == deviceId
        else { return nil }
        return file.snapshot
    }

    /// Written soon, for the pairing stored now; unpaired, it is not kept.
    public func saveSnapshot(_ snapshot: CachedSnapshot) {
        guard let deviceId = readPairing()?.deviceId else { return }
        let file = SnapshotFile(deviceId: deviceId, snapshot: snapshot)
        queue.async { [snapshotFile] in
            Self.write(file, to: snapshotFile)
        }
    }

    /// Returns once every snapshot saved so far is written.
    public func waitForSnapshotWrites() {
        queue.sync {}
    }

    /// Not written at all unless its folder is excluded from backup.
    private static func write(_ file: SnapshotFile, to url: URL) {
        do {
            let data = try JSONEncoder().encode(file)
            try makeFolderExcludedFromBackup(url.deletingLastPathComponent())
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("writing the snapshot failed: \(error)")
        }
    }

    /// Creates `folder` if it is not there, and marks it excluded from backup (again: it is cheap, and a folder that was
    /// there before gets it too).
    private static func makeFolderExcludedFromBackup(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var folder = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    /// After the writes queued before it, and done when this returns.
    private func dropSnapshot() {
        queue.sync { [snapshotFile] in
            try? FileManager.default.removeItem(at: snapshotFile)
        }
    }
}
