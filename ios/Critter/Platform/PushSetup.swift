import CritterClient
import CritterKit
import Foundation
import Observation
import os
import UIKit
import UserNotifications

/// What the phone registers for push with its Mac (spec §6.2, §8.3, §8.8), put together from the system and the
/// settings and handed to the store (`BridgeStore.setPush`), which sends it when `PushRegistrar` says so:
/// - the APNs device token, asked for at every launch (`registerForRemoteNotifications`, which needs no permission: the
///   Live Activity is pushed to a token too) and kept in the shared keychain, as hex;
/// - the push key, made the first time it is needed (`PushCrypto.makeKey`) and kept in the shared keychain, where the
///   notification service extension opens pushes with it; never logged, never in an App Group file (spec §10);
/// - whether notifications may be shown, the done and error reminders and the Live Activity switch;
/// - the environment: `sandbox` in DEBUG builds, `production` otherwise.
///
/// One for the app's life (`shared`): the app delegate hands it the token, possibly before the app has attached the
/// store; nothing is registered until both are there.
@MainActor @Observable
final class PushSetup {
    static let shared = PushSetup()

    /// What the system says about showing notifications; `.notDetermined` until it has been read.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private weak var store: BridgeStore?
    @ObservationIgnored private var settings: PhoneSettings?
    @ObservationIgnored private var deviceToken: String?
    @ObservationIgnored private var askedForToken = false
    /// The permission has been read once: before that nothing is handed on, so a token that comes first does not make a
    /// registration that says notifications are off.
    @ObservationIgnored private var authorizationRead = false

    private static let log = Logger(subsystem: "com.braynlabs.critter", category: "notifications")
    private static let tokenAccount = "deviceToken"

    #if DEBUG
    static let environment = PushEnvironment.sandbox
    #else
    static let environment = PushEnvironment.production
    #endif

    private init() {
        if case .found(let data) = SharedKeychain.push.read(Self.tokenAccount) {
            deviceToken = String(data: data, encoding: .utf8)
        }
    }

    /// Whether the system lets the app show notifications (provisional and ephemeral count).
    var notificationsAllowed: Bool {
        switch authorization {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    /// The store and the settings to register with: from now on every change goes to the store.
    func attach(store: BridgeStore, settings: PhoneSettings) {
        self.store = store
        self.settings = settings
        if !askedForToken {
            askedForToken = true
            UIApplication.shared.registerForRemoteNotifications()
        }
        Task { await refresh() }
    }

    /// Reads the permission again (it may have changed in the system's settings) and hands the store what to register.
    func refresh() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        authorizationRead = true
        update()
    }

    /// Asks the user to let the app show notifications (the first-launch guide, the settings); whether they did.
    @discardableResult
    func requestPermission() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]))
            ?? false
        await refresh()
        return granted
    }

    /// The system gave the app its APNs device token (again, or a new one).
    func tokenArrived(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        Self.log.notice("device token \(hex.prefix(8), privacy: .public)… (\(token.count) bytes)")
        guard hex != deviceToken else { return update() }
        deviceToken = hex
        let status = SharedKeychain.push.write(Data(hex.utf8), account: Self.tokenAccount)
        if status != errSecSuccess { Self.log.error("keeping the device token failed: \(status)") }
        update()
    }

    func tokenFailed(_ error: any Error) {
        Self.log.error("no device token: \(error.localizedDescription, privacy: .public)")
    }

    /// The registration as things are now, to the store (which sends it only when it changed).
    func update() {
        guard authorizationRead, let store, let settings, let key = Self.pushKey() else { return }
        let registrar = PushRegistrar(
            deviceToken: deviceToken, environment: Self.environment,
            bundleId: Bundle.main.bundleIdentifier ?? "com.braynlabs.critter", key: key,
            notificationsAllowed: notificationsAllowed, notifyDone: settings.notifyDone, notifyError: settings.notifyError,
            liveActivity: ActivityRegistration(enabled: settings.liveActivity)
        )
        if registrar != store.push {
            Self.log.notice(
                "registration: token \(self.deviceToken.map { String($0.prefix(8)) + "…" } ?? "none", privacy: .public), \(Self.environment.rawValue, privacy: .public), notifications \(registrar.notificationsAllowed), done \(registrar.notifyDone), error \(registrar.notifyError), live activity \(registrar.liveActivity.enabled)"
            )
        }
        store.setPush(registrar)
    }

    /// The push key: the one in the shared keychain, or a new one saved there. Nil when the keychain cannot be read or
    /// written now (it is tried again on the next update): a key made but not kept would be one the extension never
    /// sees.
    private static func pushKey() -> String? {
        switch SharedKeychain.push.read(SharedKeychain.pushKeyAccount) {
        case .found(let data):
            if let key = String(data: data, encoding: .utf8), PushCrypto.keyData(key) != nil { return key }
            log.error("the stored push key is not one: a new one is made")
        case .missing:
            break
        case .failed(let status):
            log.error("reading the push key failed: \(status)")
            return nil
        }
        let key = PushCrypto.makeKey()
        let status = SharedKeychain.push.write(Data(key.utf8), account: SharedKeychain.pushKeyAccount)
        guard status == errSecSuccess else {
            log.error("keeping a new push key failed: \(status)")
            return nil
        }
        log.notice("made a new push key")
        return key
    }
}
