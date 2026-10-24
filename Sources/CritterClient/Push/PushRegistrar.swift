import CritterKit

/// What the phone keeps of its push registration with the paired Mac, across launches (`PushAckStorage`). It
/// belongs to the pairing: a new one, or unpairing, starts it over.
public struct PushAck: Codable, Equatable, Sendable {
    /// The registration the Mac last stored, and what it said with it ("已登记", "已登记；这台 Mac 还没配置推送";
    /// nil from a Mac that said nothing).
    public var stored: PushRegistration?
    public var message: String?
    /// The version (`welcome.version`) of the Mac that stored it.
    public var storedBy: String?
    /// The version of a Mac that sent nothing back to a registration: it does not know the frame, so it is not
    /// tried again until it runs another version.
    public var silentMacVersion: String?
    /// The last registration the Mac refused, and its words, for the settings until another is sent.
    public var refused: PushRegistration?
    public var refusal: String?

    public init() {}
}

/// Where `PushAck` is kept. Called on the main actor.
public protocol PushAckStorage: Sendable {
    func loadPushAck() -> PushAck?
    func savePushAck(_ ack: PushAck?)
}

/// Keeps `PushAck` for as long as the app runs: until a store that outlasts it is given.
public final class MemoryPushAckStorage: PushAckStorage, @unchecked Sendable {
    private var ack: PushAck?

    public init() {}

    public func loadPushAck() -> PushAck? { ack }
    public func savePushAck(_ ack: PushAck?) { self.ack = ack }
}

/// What the phone tells the Mac so that it can push to it (spec §6.2), when it does (§8.3), and what the settings say
/// about it (§8.8). Pure: the phone's side of things goes in, the caller sends `registration()` when `shouldSend`, and
/// keeps what `record` gives back.
public struct PushRegistrar: Equatable, Sendable {
    /// The APNs device token, hex; nil until the system has given one.
    public var deviceToken: String?
    public var environment: PushEnvironment
    public var bundleId: String
    /// The push key (`PushCrypto.makeKey()`).
    public var key: String
    /// The system lets the app show notifications.
    public var notificationsAllowed: Bool
    public var notifyDone: Bool
    public var notifyError: Bool
    /// The Live Activity switch, and the tokens there are.
    public var liveActivity: ActivityRegistration

    /// What the Mac says when it can push to a registration (`BridgeConnection.storedPushMessage`).
    public static let registeredLine = "已登记"
    public static let oldMacLine = "这台 Mac 上的 Critter 版本太旧，收不到推送"
    public static let notRegisteredLine = "还没登记（要连上 Mac）"
    public static let notificationsOffLine = "通知被关掉了，去系统设置打开"

    public init(
        deviceToken: String?, environment: PushEnvironment, bundleId: String, key: String, notificationsAllowed: Bool,
        notifyDone: Bool, notifyError: Bool, liveActivity: ActivityRegistration
    ) {
        self.deviceToken = deviceToken
        self.environment = environment
        self.bundleId = bundleId
        self.key = key
        self.notificationsAllowed = notificationsAllowed
        self.notifyDone = notifyDone
        self.notifyError = notifyError
        self.liveActivity = liveActivity
    }

    /// Whether the phone wants any push at all: notifications it may show, or a Live Activity. (A waiting session is
    /// always pushed, so the reminders being off is not "nothing".)
    public var wantsPushes: Bool { notificationsAllowed || liveActivity.enabled }

    /// What to send: everything, complete. With no pushes wanted, the unregistration: an empty token is the only way
    /// to take a registration back (protocol doc). Without a device token yet, the same shape -- but `shouldSend`
    /// does not send it then.
    public func registration() -> PushRegistration {
        guard wantsPushes, let token = Self.hex(deviceToken) else { return unregistration() }
        let activity = ActivityRegistration(
            enabled: liveActivity.enabled, startToken: Self.hex(liveActivity.startToken),
            activityId: liveActivity.activityId.flatMap { $0.isEmpty ? nil : $0 },
            activityToken: Self.hex(liveActivity.activityToken)
        )
        return PushRegistration(
            token: token, environment: environment, bundleId: bundleId, key: key, notifyDone: notifyDone,
            notifyError: notifyError, activity: activity
        )
    }

    /// The registration taken back: an empty token (the Mac ignores the rest).
    public func unregistration() -> PushRegistration {
        PushRegistration(token: "", environment: environment, bundleId: bundleId, key: key, notifyDone: false, notifyError: false)
    }

    /// Whether to send `registration()` to the Mac now, connected to one that runs `macVersion`: when it is not what
    /// the Mac last stored. Never to a Mac of a version that sent nothing back. Not while there is no device token
    /// (it comes a moment after launch; an unregistration needs none). And once more for a Mac that may not have it
    /// any more or may say more now: one that runs another version than the one that stored it, or one that had no
    /// push setup then. (The caller sends one registration once per connection.)
    public func shouldSend(acked: PushAck, macVersion: String?) -> Bool {
        if let silent = acked.silentMacVersion, silent == Self.versionKey(macVersion) { return false }
        let current = registration()
        if current.token.isEmpty && wantsPushes { return false }
        guard current == acked.stored else { return true }
        if acked.storedBy != macVersion { return true }
        if let message = acked.message, message != Self.registeredLine { return true }
        return false
    }

    /// Whether unpairing should take the registration back first: the Mac may have one (it stored one, or it was sent
    /// and the reply did not say), unless the Mac does not know the frame.
    public func shouldUnregister(acked: PushAck, macVersion: String?) -> Bool {
        if let silent = acked.silentMacVersion, silent == Self.versionKey(macVersion) { return false }
        return acked.stored.map { !$0.token.isEmpty } ?? true
    }

    /// What to keep after the Mac's `reply` to `sent` (from a Mac that runs `macVersion`): a stored registration and
    /// what the Mac said, a Mac that sent nothing back, or a refusal. Cut off on its way: nothing changes.
    public func record(reply: PushRegistrationReply, sent: PushRegistration, macVersion: String?, acked: PushAck) -> PushAck {
        var next = acked
        switch reply {
        case .stored(let message):
            next.stored = sent
            next.message = message
            next.storedBy = macVersion
            next.silentMacVersion = nil
            next.refused = nil
            next.refusal = nil
        case .noReply:
            next.silentMacVersion = Self.versionKey(macVersion)
        case .rejected(let message):
            next.refused = sent
            next.refusal = message
        case .offline:
            break
        }
        return next
    }

    /// The settings' line about push (spec §8.8): what the user can do something about first, then the Mac's word.
    public func status(acked: PushAck, macVersion: String?) -> String {
        if !notificationsAllowed { return Self.notificationsOffLine }
        if let silent = acked.silentMacVersion, silent == Self.versionKey(macVersion) { return Self.oldMacLine }
        let current = registration()
        if !current.token.isEmpty, current == acked.stored { return acked.message ?? Self.registeredLine }
        if current == acked.refused, let refusal = acked.refusal { return refusal }
        return Self.notRegisteredLine
    }

    /// A Mac version as `PushAck` keeps it: "" for a Mac that names none.
    private static func versionKey(_ version: String?) -> String {
        version ?? ""
    }

    /// An APNs token as the Mac takes it: lowercase hex; nil for none or an empty one.
    private static func hex(_ token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        return token.lowercased()
    }
}
