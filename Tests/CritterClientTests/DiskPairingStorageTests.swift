import CritterClient
import CritterKit
import Foundation
import os
import Testing

/// Secrets in memory, as the keychain keeps them; writes can be made to fail, as the keychain's do (locked, or a build
/// without the keychain group).
final class FakeSecrets: SecretStore {
    private struct State {
        var items: [String: String] = [:]
        var failWrites = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var items: [String: String] { state.withLock { $0.items } }
    func failWrites(_ fail: Bool) { state.withLock { $0.failWrites = fail } }

    func secret(_ account: String) -> String? { state.withLock { $0.items[account] } }

    func setSecret(_ secret: String, for account: String) -> Bool {
        state.withLock { s in
            guard !s.failWrites else { return false }
            s.items[account] = secret
            return true
        }
    }

    func removeSecret(_ account: String) { state.withLock { _ = $0.items.removeValue(forKey: account) } }

    func accounts() -> [String]? { state.withLock { Array($0.items.keys) } }
}

/// A folder of its own for each test, standing in for the App Group's.
struct StorageFolder {
    let url = FileManager.default.temporaryDirectory.appending(path: "critter-storage-\(UUID().uuidString)")

    var pairingFile: URL { url.appending(path: "Pairing/pairing.json") }
    var snapshotFile: URL { url.appending(path: "Snapshot/snapshot.json") }

    func storage(_ secrets: FakeSecrets) -> DiskPairingStorage {
        DiskPairingStorage(tokens: secrets, pairingFile: pairingFile, snapshotFile: snapshotFile)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

private let macA = StoredPairing(
    endpoint: Endpoint(host: "192.168.1.20", port: 47823), fingerprint: String(repeating: "ab", count: 32),
    macName: "Mac A", deviceId: "dA"
)
private let macB = StoredPairing(
    endpoint: Endpoint(host: "192.168.1.30", port: 47823), fingerprint: String(repeating: "cd", count: 32),
    macName: "Mac B", deviceId: "dB"
)

private func cached(_ id: String, at seconds: TimeInterval = 1_800_000_000) -> CachedSnapshot {
    CachedSnapshot(body: fixtureBody([fixtureSession(id)]), receivedAt: Date(timeIntervalSince1970: seconds))
}

struct DiskPairingStorageTests {
    @Test func aPairingOutlivesTheApp() throws {
        let folder = StorageFolder()
        defer { folder.remove() }
        let secrets = FakeSecrets()
        #expect(folder.storage(secrets).save(macA, token: "token-A"))

        // The next launch.
        let next = folder.storage(secrets)
        let loaded = try #require(next.load())
        #expect(loaded.0 == macA)
        #expect(loaded.1 == Credentials(deviceId: "dA", token: "token-A"))
        // The token is a secret, under the device id; the file has everything else and not the token.
        #expect(secrets.items == ["dA": "token-A"])
        let file = try String(contentsOf: folder.pairingFile, encoding: .utf8)
        #expect(file.contains("Mac A"))
        #expect(!file.contains("token-A"))
    }

    @Test func aPairingWhoseTokenIsGoneIsNoPairing() {
        let folder = StorageFolder()
        defer { folder.remove() }
        let secrets = FakeSecrets()
        let storage = folder.storage(secrets)
        #expect(storage.save(macA, token: "token-A"))
        secrets.removeSecret("dA")
        #expect(storage.load() == nil)
    }

    /// Ledger: the old token was deleted first and the record written even when the new token could not be, so the
    /// next launch was unpaired. Now the new token goes first, and only once it is in does anything else change.
    @Test func aFailedTokenWriteKeepsTheOldPairing() throws {
        let folder = StorageFolder()
        defer { folder.remove() }
        let secrets = FakeSecrets()
        let storage = folder.storage(secrets)
        #expect(storage.save(macA, token: "token-A"))
        storage.saveSnapshot(cached("a"))
        storage.waitForSnapshotWrites()

        secrets.failWrites(true)
        #expect(!storage.save(macB, token: "token-B"))

        for current in [storage, folder.storage(secrets)] {
            let loaded = try #require(current.load())
            #expect(loaded.0 == macA)
            #expect(loaded.1 == Credentials(deviceId: "dA", token: "token-A"))
            #expect(current.loadSnapshot() == cached("a"))
        }
        #expect(secrets.items == ["dA": "token-A"])
    }

    /// Once the new token is in, the old one goes.
    @Test func aNewPairingReplacesTheOldToken() throws {
        let folder = StorageFolder()
        defer { folder.remove() }
        let secrets = FakeSecrets()
        let storage = folder.storage(secrets)
        #expect(storage.save(macA, token: "token-A"))
        #expect(storage.save(macB, token: "token-B"))
        let loaded = try #require(folder.storage(secrets).load())
        #expect(loaded.0 == macB)
        #expect(loaded.1 == Credentials(deviceId: "dB", token: "token-B"))
        #expect(secrets.items == ["dB": "token-B"])
    }

    /// Ledger: deleting the old Mac's snapshot was queued, so an app killed right after pairing could show it at the
    /// next launch, and a write and the delete could cross so the cache stayed empty until the next snapshot.
    @Test func repairingNeverShowsTheOldMacsSnapshot() throws {
        let folder = StorageFolder()
        defer { folder.remove() }
        let secrets = FakeSecrets()
        let storage = folder.storage(secrets)
        #expect(storage.save(macA, token: "token-A"))
        storage.saveSnapshot(cached("old"))
        storage.waitForSnapshotWrites()
        let oldFile = try Data(contentsOf: folder.snapshotFile)
        // Queued and not written yet when the new pairing is saved.
        storage.saveSnapshot(cached("old", at: 1_800_000_030))
        #expect(storage.save(macB, token: "token-B"))

        // Gone at once, and nothing queued before the new pairing comes back after it.
        #expect(storage.loadSnapshot() == nil)
        storage.waitForSnapshotWrites()
        #expect(storage.loadSnapshot() == nil)
        #expect(folder.storage(secrets).loadSnapshot() == nil)

        // Even if the old file were still there (the app killed between writing the pairing and deleting it), it is
        // the old Mac's and is not read for the new pairing.
        try FileManager.default.createDirectory(at: folder.snapshotFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try oldFile.write(to: folder.snapshotFile)
        #expect(folder.storage(secrets).loadSnapshot() == nil)

        // The new Mac's first snapshot is kept.
        storage.saveSnapshot(cached("new"))
        storage.waitForSnapshotWrites()
        #expect(folder.storage(secrets).loadSnapshot() == cached("new"))
    }

    @Test func aSnapshotSavedBeforeUnpairingIsNotWrittenAfterIt() {
        let folder = StorageFolder()
        defer { folder.remove() }
        let secrets = FakeSecrets()
        let storage = folder.storage(secrets)
        #expect(storage.save(macA, token: "token-A"))
        storage.saveSnapshot(cached("a"))
        storage.clear()
        storage.waitForSnapshotWrites()
        #expect(storage.load() == nil)
        #expect(storage.loadSnapshot() == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.snapshotFile.path))
        #expect(!FileManager.default.fileExists(atPath: folder.pairingFile.path))
        #expect(secrets.items.isEmpty)
        // Unpaired, nothing is cached.
        storage.saveSnapshot(cached("b"))
        storage.waitForSnapshotWrites()
        #expect(!FileManager.default.fileExists(atPath: folder.snapshotFile.path))
    }

    @Test func theSnapshotStaysOutOfBackups() throws {
        let folder = StorageFolder()
        defer { folder.remove() }
        let storage = folder.storage(FakeSecrets())
        #expect(storage.save(macA, token: "token-A"))
        storage.saveSnapshot(cached("a"))
        storage.waitForSnapshotWrites()
        let values = try folder.snapshotFile.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func aNewAddressKeepsTheTokenAndTheSnapshot() throws {
        let folder = StorageFolder()
        defer { folder.remove() }
        let secrets = FakeSecrets()
        let storage = folder.storage(secrets)
        #expect(storage.save(macA, token: "token-A"))
        storage.saveSnapshot(cached("a"))
        storage.waitForSnapshotWrites()
        let moved = Endpoint(host: "192.168.1.77", port: 47823)
        storage.updateEndpoint(moved)
        let loaded = try #require(folder.storage(secrets).load())
        #expect(loaded.0.endpoint == moved)
        #expect(loaded.1.token == "token-A")
        #expect(folder.storage(secrets).loadSnapshot() == cached("a"))
    }
}

struct SecretPushAckStorageTests {
    @Test func aPushAckOutlivesTheApp() {
        let secrets = FakeSecrets()
        var ack = PushAck()
        ack.stored = PushRegistration(
            token: "aa11", environment: .sandbox, bundleId: "com.braynlabs.critter", key: PushCrypto.makeKey(),
            notifyDone: false, notifyError: true
        )
        ack.message = "已登记"
        ack.storedBy = "1.4.0"
        SecretPushAckStorage(secrets: secrets).savePushAck(ack)
        #expect(SecretPushAckStorage(secrets: secrets).loadPushAck() == ack)
        // It holds the push key (in the registration), so it is a secret too, not a file.
        #expect(secrets.items.keys.sorted() == [SecretPushAckStorage.account])
    }

    @Test func forgettingTheAckDeletesIt() {
        let secrets = FakeSecrets()
        var ack = PushAck()
        ack.silentMacVersion = "1.0"
        let storage = SecretPushAckStorage(secrets: secrets)
        storage.savePushAck(ack)
        storage.savePushAck(nil)
        #expect(storage.loadPushAck() == nil)
        #expect(secrets.items.isEmpty)
    }
}
