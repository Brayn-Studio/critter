#if DEBUG
import Foundation
import os
import UserNotifications

/// The extension's half of `-critterSharedCheck` (the app's `Debug/SharedCheck.swift`): a push with
/// `"critterSharedCheck": 1` reads the app's markers (`SharedCheck/app.txt` in the App Group, account `app` in the
/// shared keychain), writes its own (`notify.txt`, account `notify`), logs what it found (subsystem
/// `com.braynlabs.critter`, category `sharedcheck`) and shows it as the notification's text.
enum SharedCheck {
    private static let log = Logger(subsystem: "com.braynlabs.critter", category: "sharedcheck")

    static func answer(_ content: UNMutableNotificationContent) {
        let raw = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedContainer.appGroup)
        say("notify: container \(raw?.path ?? "nil")")
        say("notify: keychain group \(SharedContainer.keychainGroup)")
        let folder = SharedContainer.url.appending(path: "SharedCheck", directoryHint: .isDirectory)
        let file = (try? String(contentsOf: folder.appending(path: "app.txt"), encoding: .utf8)) ?? "nil"
        let keychain = SharedKeychain(service: "com.braynlabs.critter.sharedcheck")
        let item = describe(keychain.read("app"))
        say("notify: app.txt -> \(file)")
        say("notify: keychain read app -> \(item)")
        let marker = "notify \(Date().formatted(.iso8601)) saw [\(file)] [\(item)]"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: folder.appending(path: "notify.txt"), options: .atomic)
            say("notify: wrote notify.txt")
        } catch {
            say("notify: writing notify.txt failed: \(error)")
        }
        say("notify: keychain write notify -> \(keychain.write(Data(marker.utf8), account: "notify"))")
        content.title = "shared check"
        content.body = "file [\(file)] keychain [\(item)]"
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
