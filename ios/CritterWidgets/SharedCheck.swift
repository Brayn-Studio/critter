#if DEBUG
import CritterKit
import Foundation
import os

/// The widget extension's half of `-critterSharedCheck` (the app's `Debug/SharedCheck.swift`): `xcrun simctl push`
/// does not wake the notification service extension in the simulator, so the app also starts a Live Activity whose
/// `total` is `marker`, and drawing it here reads the app's markers (`SharedCheck/app.txt` in the App Group, account
/// `app` in the shared keychain group the app names in `keychain-group.txt`) and writes this extension's own
/// (`widgets.txt`, account `widgets`). The log says what it found (subsystem `com.braynlabs.critter`, category
/// `sharedcheck`). This extension has no keychain group of its own, so its keychain read is expected to fail
/// (`errSecMissingEntitlement`) unless one is added to its entitlements for the check.
enum SharedCheck {
    static let marker = 4242
    private static let log = Logger(subsystem: "com.braynlabs.critter", category: "sharedcheck")

    static func answerIfAsked(_ state: LiveActivityContent) {
        guard state.total == marker else { return }
        let raw = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedContainer.appGroup)
        say("widgets: container \(raw?.path ?? "nil")")
        let folder = SharedContainer.url.appending(path: "SharedCheck", directoryHint: .isDirectory)
        let file = (try? String(contentsOf: folder.appending(path: "app.txt"), encoding: .utf8)) ?? "nil"
        let group = (try? String(contentsOf: folder.appending(path: "keychain-group.txt"), encoding: .utf8)) ?? ""
        let keychain = SharedKeychain(service: "com.braynlabs.critter.sharedcheck", group: group)
        let item = describe(keychain.read("app"))
        say("widgets: app.txt -> \(file)")
        say("widgets: keychain group \(group) read app -> \(item)")
        let marker = "widgets \(Date().formatted(.iso8601)) saw [\(file)] [\(item)]"
        do {
            try Data(marker.utf8).write(to: folder.appending(path: "widgets.txt"), options: .atomic)
            say("widgets: wrote widgets.txt")
        } catch {
            say("widgets: writing widgets.txt failed: \(error)")
        }
        say("widgets: keychain write widgets -> \(keychain.write(Data(marker.utf8), account: "widgets"))")
    }

    private static func describe(_ read: SharedKeychain.Read) -> String {
        switch read {
        case .found(let data): "found \(String(decoding: data, as: UTF8.self))"
        case .missing: "missing"
        case .failed(let status): "failed \(status)"
        }
    }

    private static func say(_ line: String) {
        log.notice("\(line, privacy: .public)")
    }
}
#endif
