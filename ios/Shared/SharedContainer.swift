import Foundation
import os
import Security

/// What the app and its extensions share (spec §8.1): the App Group's folder and defaults, and the keychain group.
/// All three come from the entitlements in `Config/*.entitlements`; nothing is registered with the developer account
/// for them (in the simulator the entitlements in the binary are all it takes).
///
/// - `Pairing/`: the pairing record (address, port, fingerprint, the Mac's name, the device id). Nothing secret: the
///   token and the push key are in the keychain (`SharedKeychain`), never in a file here.
/// - `Snapshot/`: the last snapshot. It holds session names, commands and paths, so the folder is excluded from
///   backup (spec §3: no session content goes to Apple).
/// - `Skins/`: the custom skins the Mac sent, which the Live Activity draws too.
/// - `defaults`: the settings the extensions read as well (the Live Activity switch, the done and error alerts).
enum SharedContainer {
    static let appGroup = "group.com.braynlabs.critter"

    /// `$(AppIdentifierPrefix)com.braynlabs.critter.shared`: the build writes it into Info.plist
    /// (`CritterKeychainGroup`) of each target that has it, with the prefix filled in.
    static let keychainGroup = Bundle.main.object(forInfoDictionaryKey: "CritterKeychainGroup") as? String ?? ""

    private static let log = Logger(subsystem: "com.braynlabs.critter", category: "storage")

    /// The App Group's folder. Without the entitlement (a build signed without it) there is none, and the app's own
    /// Application Support stands in, so the app still works (the extensions then see nothing of it).
    static var url: URL {
        if let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return shared
        }
        log.fault("no App Group container for \(appGroup, privacy: .public): the app's own folder stands in")
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var pairingFolder: URL { url.appending(path: "Pairing", directoryHint: .isDirectory) }
    static var snapshotFolder: URL { url.appending(path: "Snapshot", directoryHint: .isDirectory) }
    static var skinsFolder: URL { url.appending(path: "Skins", directoryHint: .isDirectory) }

    /// The settings the extensions read too. Without the entitlement, the app's own.
    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }
}

/// Generic passwords of one service in the shared keychain group (`SharedContainer.keychainGroup`), readable after the
/// first unlock and on this device only: the notification service extension and the background answers run while the
/// phone is locked, and nothing here goes into a backup or onto another phone (spec §8.1, §10).
struct SharedKeychain: Sendable {
    let service: String
    var group = SharedContainer.keychainGroup

    /// What a read found: the item's data, nothing (`errSecItemNotFound`), or another status (the keychain could not be
    /// read, as before the first unlock).
    enum Read: Equatable, Sendable {
        case found(Data)
        case missing
        case failed(OSStatus)
    }

    private var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: group,
        ]
    }

    func read(_ account: String) -> Read {
        var query = base
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return (item as? Data).map(Read.found) ?? .failed(errSecInternalError)
        case errSecItemNotFound: return .missing
        default: return .failed(status)
        }
    }

    /// Saves `data` under `account`, replacing what is there. `errSecSuccess`, or why it was not saved.
    @discardableResult
    func write(_ data: Data, account: String) -> OSStatus {
        var query = base
        query[kSecAttrAccount as String] = account
        let changes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        guard updated == errSecItemNotFound else { return updated }
        query.merge(changes) { _, new in new }
        return SecItemAdd(query as CFDictionary, nil)
    }

    /// Deletes `account`'s item; `errSecSuccess` also when there was none.
    @discardableResult
    func delete(_ account: String) -> OSStatus {
        var query = base
        query[kSecAttrAccount as String] = account
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }

    /// The accounts this service has items under; nil if the keychain could not be read.
    func accounts() -> [String]? {
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            return (items as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound: return []
        default: return nil
        }
    }
}

extension SharedKeychain {
    /// The pairing's token, under the pairing's device id.
    static let pairingTokens = SharedKeychain(service: "com.braynlabs.critter.pairing")
    /// Push: the key that seals notification text (account `pushKeyAccount`, which the notification service extension
    /// opens them with), and what the Mac confirmed of the push registration (account `ack`, the app's only).
    static let push = SharedKeychain(service: "com.braynlabs.critter.push")
    static let pushKeyAccount = "key"
}
