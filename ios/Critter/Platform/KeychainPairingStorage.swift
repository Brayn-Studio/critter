import CritterClient
import CritterKit
import Foundation
import os
import Security

/// Where the phone keeps its pairing: the pairing itself as JSON text in `UserDefaults` (`critter.pairing`), its
/// token in the keychain (service `com.braynlabs.critter.pairing`, account = the pairing's device id, this device
/// only, readable after the first unlock), and the last snapshot in Application Support/`Snapshot/snapshot.json`.
///
/// The snapshot holds commands, plan text, paths and the names of sessions and the Mac: it stays out of iCloud and
/// computer backups (spec §3: no session content goes to Apple). Its folder is marked excluded from backup, which
/// covers the file inside it however often an atomic write replaces it.
///
/// A token is only ever read under the device id of the pairing stored, so a pairing and someone else's token never
/// make up the credentials, even if the app stopped halfway through `save`.
///
/// The store saves every snapshot on the main actor, and a snapshot can be over a megabyte: they are encoded and
/// written on a private serial queue (atomically), and when several arrive while one is being written only the newest
/// is written next. Deleting the file goes through the same queue, so a snapshot saved before `save` or `clear` is
/// never written after it.
final class KeychainPairingStorage: PairingStorage {
    private static let pairingKey = "critter.pairing"
    private static let service = "com.braynlabs.critter.pairing"
    private static let log = Logger(subsystem: "com.braynlabs.critter", category: "storage")

    private let snapshotURL: URL
    private let queue = DispatchQueue(label: "com.braynlabs.critter.snapshot", qos: .utility)
    /// The newest snapshot saved and not taken by the writer yet; a write is queued while it is set.
    private let unwritten = OSAllocatedUnfairLock<CachedSnapshot?>(initialState: nil)

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        snapshotURL = support.appending(path: "Snapshot", directoryHint: .isDirectory).appending(path: "snapshot.json")
    }

    // MARK: - The pairing

    func load() -> (StoredPairing, Credentials)? {
        guard let pairing = Self.readPairing(), let token = Self.readToken(account: pairing.deviceId) else { return nil }
        return (pairing, Credentials(deviceId: pairing.deviceId, token: token))
    }

    /// Also drops the cached snapshot: it is the replaced pairing's, maybe another Mac's.
    func save(_ pairing: StoredPairing, token: String) {
        dropSnapshot()
        Self.deleteTokens()
        Self.addToken(token, account: pairing.deviceId)
        Self.writePairing(pairing)
    }

    func updateEndpoint(_ endpoint: Endpoint) {
        guard var pairing = Self.readPairing() else { return }
        pairing.endpoint = endpoint
        Self.writePairing(pairing)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: Self.pairingKey)
        Self.deleteTokens()
        dropSnapshot()
    }

    private static func readPairing() -> StoredPairing? {
        guard let text = UserDefaults.standard.string(forKey: pairingKey) else { return nil }
        return try? JSONDecoder().decode(StoredPairing.self, from: Data(text.utf8))
    }

    private static func writePairing(_ pairing: StoredPairing) {
        guard let data = try? JSONEncoder().encode(pairing) else { return }
        UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: pairingKey)
    }

    // MARK: - The token

    private static var tokenItems: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    private static func readToken(account: String) -> String? {
        var query = tokenItems
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound { log.error("reading the token failed: \(status)") }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func addToken(_ token: String, account: String) {
        var item = tokenItems
        item[kSecAttrAccount as String] = account
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { log.error("saving the token failed: \(status)") }
    }

    /// Every token of this service: there is only ever one pairing.
    private static func deleteTokens() {
        let status = SecItemDelete(tokenItems as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound { log.error("deleting the token failed: \(status)") }
    }

    // MARK: - The snapshot

    /// Read at launch, on the caller's thread.
    func loadSnapshot() -> CachedSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode(CachedSnapshot.self, from: data)
    }

    func saveSnapshot(_ snapshot: CachedSnapshot) {
        let writeQueued = unwritten.withLock { slot in
            let queued = slot != nil
            slot = snapshot
            return queued
        }
        guard !writeQueued else { return }
        queue.async { [self] in
            guard let newest = unwritten.withLock({ slot in
                defer { slot = nil }
                return slot
            }) else { return }
            write(newest)
        }
    }

    /// Not written at all unless its folder is excluded from backup.
    private func write(_ snapshot: CachedSnapshot) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try Self.makeFolderExcludedFromBackup(snapshotURL.deletingLastPathComponent())
            try data.write(to: snapshotURL, options: .atomic)
        } catch {
            Self.log.error("writing the snapshot failed: \(error)")
        }
    }

    /// Creates `folder` if it is not there, and marks it excluded from backup (again: it is cheap, and a folder
    /// that was there before gets it too).
    private static func makeFolderExcludedFromBackup(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var folder = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    private func dropSnapshot() {
        unwritten.withLock { $0 = nil }
        queue.async { [snapshotURL] in
            try? FileManager.default.removeItem(at: snapshotURL)
        }
    }
}
