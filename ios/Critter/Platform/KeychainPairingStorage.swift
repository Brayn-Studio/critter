import CritterClient
import Foundation
import os
import Security

/// One service of the shared keychain group as CritterClient's `SecretStore` (`SharedKeychain`: readable after the
/// first unlock, this device only). A read that fails for another reason than "not there" is logged (with the status
/// only, never the secret) and counts as nothing there.
struct KeychainSecrets: SecretStore {
    let keychain: SharedKeychain
    private static let log = Logger(subsystem: "com.braynlabs.critter", category: "storage")

    func secret(_ account: String) -> String? {
        switch keychain.read(account) {
        case .found(let data): return String(data: data, encoding: .utf8)
        case .missing: return nil
        case .failed(let status):
            Self.log.error("reading \(keychain.service, privacy: .public) failed: \(status)")
            return nil
        }
    }

    func setSecret(_ secret: String, for account: String) -> Bool {
        let status = keychain.write(Data(secret.utf8), account: account)
        if status != errSecSuccess { Self.log.error("saving \(keychain.service, privacy: .public) failed: \(status)") }
        return status == errSecSuccess
    }

    func removeSecret(_ account: String) {
        let status = keychain.delete(account)
        if status != errSecSuccess { Self.log.error("deleting \(keychain.service, privacy: .public) failed: \(status)") }
    }

    func accounts() -> [String]? {
        keychain.accounts()
    }
}

extension DiskPairingStorage {
    /// Where the app keeps its pairing (spec §8.1): the record in the App Group's `Pairing/pairing.json`, its token in
    /// the shared keychain (service `com.braynlabs.critter.pairing`, account = the pairing's device id), and the last
    /// snapshot in the App Group's `Snapshot/snapshot.json`, out of backups. Nothing is read from where an earlier
    /// build kept them (standard defaults, Application Support): no build with those ever went onto a phone.
    static func inAppGroup() -> DiskPairingStorage {
        DiskPairingStorage(
            tokens: KeychainSecrets(keychain: .pairingTokens),
            pairingFile: SharedContainer.pairingFolder.appending(path: "pairing.json"),
            snapshotFile: SharedContainer.snapshotFolder.appending(path: "snapshot.json")
        )
    }
}

extension SecretPushAckStorage {
    /// What the Mac confirmed of the push registration, in the shared keychain (service `com.braynlabs.critter.push`,
    /// account `ack`): it holds the push key.
    static func inKeychain() -> SecretPushAckStorage {
        SecretPushAckStorage(secrets: KeychainSecrets(keychain: .push))
    }
}
