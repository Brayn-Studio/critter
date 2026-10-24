#if DEBUG
import ActivityKit
import CritterClient
import CritterKit
import Foundation
import os
import Security
import UserNotifications

/// `-critterSharedCheck` (see `DebugLaunch`): whether the App Group and the shared keychain group work without the
/// developer account, as the entitlements in the binaries have them (plan 4, Task 4's first step). The app writes a
/// marker to `SharedCheck/app.txt` in the App Group and to the shared keychain (service
/// `com.braynlabs.critter.sharedcheck`, account `app`), reads both back with the item's group and accessibility, and
/// reads what the extensions last wrote (`notify.txt` and `widgets.txt`, accounts `notify` and `widgets`), and runs
/// the app's own storage (`DiskPairingStorage` over `KeychainSecrets`) through a pairing, a new pairing and unpairing on
/// a service and files of its own (`com.braynlabs.critter.sharedcheck.pairing`, `SharedCheck/`). It then
/// starts a Live Activity whose `total` is 4242 for five seconds: drawing it runs the widget extension's half
/// (`CritterWidgets/SharedCheck.swift`). A push with `"critterSharedCheck": 1` runs the notification service
/// extension's (`CritterNotify/SharedCheck.swift`); it asks for provisional notification permission (no prompt) so that
/// such a push is delivered. Everything goes to standard output and to the log (subsystem `com.braynlabs.critter`,
/// category `sharedcheck`).
enum SharedCheck {
    static let service = "com.braynlabs.critter.sharedcheck"
    private static let log = Logger(subsystem: "com.braynlabs.critter", category: "sharedcheck")

    @MainActor static func run() async {
        let raw = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedContainer.appGroup)
        say("app: container \(raw?.path ?? "nil")")
        say("app: keychain group \(SharedContainer.keychainGroup)")
        let folder = SharedContainer.url.appending(path: "SharedCheck", directoryHint: .isDirectory)
        let marker = "app \(Date().formatted(.iso8601)) \(UUID().uuidString.prefix(8))"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: folder.appending(path: "app.txt"), options: .atomic)
            say("app: wrote app.txt: \(marker)")
        } catch {
            say("app: writing app.txt failed: \(error)")
        }
        let keychain = SharedKeychain(service: service)
        say("app: keychain write app -> \(keychain.write(Data(marker.utf8), account: "app"))")
        say("app: keychain read app -> \(describe(keychain.read("app")))")
        say("app: keychain item app is \(attributes(service: service, account: "app"))")
        try? Data(SharedContainer.keychainGroup.utf8).write(to: folder.appending(path: "keychain-group.txt"), options: .atomic)
        say("app: notify.txt -> \((try? String(contentsOf: folder.appending(path: "notify.txt"), encoding: .utf8)) ?? "nil")")
        say("app: keychain read notify -> \(describe(keychain.read("notify")))")
        say("app: widgets.txt -> \((try? String(contentsOf: folder.appending(path: "widgets.txt"), encoding: .utf8)) ?? "nil")")
        say("app: keychain read widgets -> \(describe(keychain.read("widgets")))")
        storageRoundTrip(in: folder)
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge, .provisional])) ?? false
        let settings = await center.notificationSettings()
        say("app: notifications provisional granted \(granted), status \(settings.authorizationStatus.rawValue)")
        // The widget extension's half: drawing this Live Activity runs `CritterWidgets/SharedCheck.swift`.
        for activity in Activity<CritterActivity>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
        let state = LiveActivityContent(
            counts: [], lead: nil, back: [], total: 4242, fiveHour: nil, sevenDay: nil,
            updatedAt: Int64(Date().timeIntervalSince1970 * 1000)
        )
        do {
            let activity = try Activity.request(attributes: CritterActivity(), content: .init(state: state, staleDate: nil))
            say("app: started Live Activity \(activity.id)")
            // Drawn within a moment; it is not left on the lock screen.
            try? await Task.sleep(for: .seconds(5))
            await activity.end(nil, dismissalPolicy: .immediate)
            say("app: ended Live Activity \(activity.id)")
        } catch {
            say("app: starting the Live Activity failed: \(error)")
        }
    }

    /// The app's own storage classes (`DiskPairingStorage` over `KeychainSecrets`) on the real keychain group and App
    /// Group, with a service and files of their own: a pairing, a new one replacing it, then unpairing.
    private static func storageRoundTrip(in folder: URL) {
        let tokens = KeychainSecrets(keychain: SharedKeychain(service: service + ".pairing"))
        func storage() -> DiskPairingStorage {
            DiskPairingStorage(
                tokens: tokens, pairingFile: folder.appending(path: "pairing.json"),
                snapshotFile: folder.appending(path: "snapshot.json")
            )
        }
        func pairing(_ id: String) -> StoredPairing {
            StoredPairing(
                endpoint: Endpoint(host: "192.168.1.20", port: 47823), fingerprint: String(repeating: "0", count: 64),
                macName: "Check Mac", deviceId: id
            )
        }
        let first = storage()
        let savedA = first.save(pairing("check-a"), token: "token-a")
        first.saveSnapshot(CachedSnapshot(body: SnapshotBody(sessions: [], pending: [], prefs: BridgePrefs(
            skin: "sprig", randomSkins: false, idleDim: 1, mergeThreshold: 4, soundTheme: "pixel"
        )), receivedAt: Date()))
        first.waitForSnapshotWrites()
        let snapshotA = storage().loadSnapshot() != nil
        let savedB = first.save(pairing("check-b"), token: "token-b")
        let loaded = storage().load()
        say("app: storage saved a \(savedA), snapshot a \(snapshotA), saved b \(savedB), loads \(loaded?.1.deviceId ?? "nil")/\(loaded?.1.token ?? "nil"), snapshot after b \(storage().loadSnapshot() != nil), tokens \(tokens.accounts() ?? ["unreadable"])")
        first.clear()
        say("app: storage after clear loads \(storage().load() == nil ? "nothing" : "something"), tokens \(tokens.accounts() ?? ["unreadable"])")
    }

    /// The access group and accessibility the keychain gave `account`'s item (`cku`: after first unlock, this device
    /// only).
    private static func attributes(service: String, account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnAttributes as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let found = item as? [String: Any] else { return "unreadable \(status)" }
        return "group \(found[kSecAttrAccessGroup as String] ?? "nil"), accessible \(found[kSecAttrAccessible as String] ?? "nil")"
    }

    static func describe(_ read: SharedKeychain.Read) -> String {
        switch read {
        case .found(let data): "found \(String(decoding: data, as: UTF8.self))"
        case .missing: "missing"
        case .failed(let status): "failed \(status)"
        }
    }

    private static func say(_ line: String) {
        print("sharedcheck \(line)")
        log.notice("\(line, privacy: .public)")
    }
}
#endif
