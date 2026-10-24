import CritterKit
import Foundation
import os

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

    /// Whether the Mac may push to this phone with what it holds: it stored a registration with a token, and not an
    /// empty one since. (A refusal leaves what it stored before.)
    public var holdsRegistration: Bool {
        stored.map { !$0.token.isEmpty } ?? false
    }
}

/// Where `PushAck` is kept. Called on the main actor.
public protocol PushAckStorage: Sendable {
    func loadPushAck() -> PushAck?
    func savePushAck(_ ack: PushAck?)
}

/// Keeps `PushAck` for as long as the app runs (the app keeps it in the keychain: `SecretPushAckStorage`).
public final class MemoryPushAckStorage: PushAckStorage {
    private let ack = OSAllocatedUnfairLock<PushAck?>(initialState: nil)

    public init() {}

    public func loadPushAck() -> PushAck? { ack.withLock { $0 } }
    public func savePushAck(_ ack: PushAck?) { self.ack.withLock { $0 = ack } }
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

    /// The line about a Mac this phone left without telling it (`BridgeStore`'s `onUntoldMac`), in the settings and on
    /// the pairing screen until dismissed (spec §8.8). That Mac keeps what was registered: the device token, so it may
    /// still notify (saying only "有会话需要你" once the push key was changed, `keyChanged`), and the Live Activity's
    /// push-to-start token, which no key covers. Revoking this phone there is what ends it.
    public static func leftMacLine(_ macName: String, keyChanged: Bool) -> String {
        let what = keyChanged ? "通知（只显示「有会话需要你」）和实时活动" : "通知和实时活动"
        return "「\(macName)」没收到这台手机撤销推送的消息，可能还会发来\(what)。在那台 Mac 的 Critter 设置里，「已配对的手机」中这台手机旁点「撤销」。"
    }

    /// Whether the line about a Mac left untold (`leftMacLine`) still stands once the phone is paired with the Mac whose
    /// certificate fingerprint is `pairedFingerprint`. Not when that is the Mac left (`leftFingerprint`, kept with the
    /// line): pairing A, then B, then A again must not go on telling the user to revoke this phone on A -- the new
    /// pairing registers the same token and A hands the old record's registration over to it. A line kept without its
    /// fingerprint, or no pairing, stands. Pure.
    public static func leftMacLineStands(leftFingerprint: String?, pairedFingerprint: String?) -> Bool {
        guard let leftFingerprint, let pairedFingerprint else { return true }
        return leftFingerprint != pairedFingerprint
    }

    /// What the unpair dialog says, instead of "不再收到提醒", when the Mac cannot be told now
    /// (`BridgeStore.unpairingLeavesTheMacUntold`).
    public static func unpairingUntoldLine(_ macName: String) -> String {
        "现在连不上「\(macName)」，没法让它停止推送：取消配对后它可能还会发来通知和实时活动，要在那台 Mac 的 Critter 设置里，「已配对的手机」中这台手机旁点「撤销」。之后要用，得在 Mac 上重新「添加手机」再扫码。"
    }

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

    /// What to take back from a Mac this phone is leaving (unpairing, or pairing with another, spec §8.8): the empty
    /// token when the Mac may have a registration (`shouldUnregister`); nil when there is nothing to take back. Before
    /// the app has said what to register this run (`registrar` nil), from what the Mac last stored, with its key.
    public static func takingBack(_ registrar: PushRegistrar?, acked: PushAck, macVersion: String?) -> PushRegistration? {
        if let registrar {
            return registrar.shouldUnregister(acked: acked, macVersion: macVersion) ? registrar.unregistration() : nil
        }
        if let silent = acked.silentMacVersion, silent == versionKey(macVersion) { return nil }
        guard acked.holdsRegistration, let stored = acked.stored else { return nil }
        return PushRegistration(
            token: "", environment: stored.environment, bundleId: stored.bundleId, key: stored.key, notifyDone: false,
            notifyError: false
        )
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

/// The Live Activity's tokens as the system gives them to the app (spec §6.6, §8.5), for the registration's
/// `activity`: the push-to-start token, and the running activity's id and push token. One activity is registered (the
/// app keeps one, `LocalActivity.keeper`): the first whose token comes, until it ends; the token of another one running
/// next to it is kept aside, and when the registered one ends the one with the smallest id among those takes its place.
/// Tokens of activities that ended are ignored, also when they come late. Pure; the app's `LiveActivityManager` hands in
/// what ActivityKit reports, and builds the registration from `registration(enabled:)`. Each change it reports (`true`)
/// is a new registration, which goes to the Mac at once when connected (`PushRegistrar.shouldSend`).
public struct ActivityTokens: Equatable, Sendable {
    /// Lowercase hex, as the Mac takes them.
    public private(set) var startToken: String?
    public private(set) var activityId: String?
    public private(set) var activityToken: String?
    /// The tokens of the other activities running, by id.
    private var others: [String: String] = [:]
    /// Activities that ended or were dismissed (or are being ended): their tokens are not taken.
    private var ended: Set<String> = []

    public init(startToken: String? = nil, activityId: String? = nil, activityToken: String? = nil) {
        self.startToken = startToken
        self.activityId = activityId
        self.activityToken = activityToken
    }

    /// The push-to-start token (`Activity.pushToStartTokenUpdates`), new or the same again. Whether it changed.
    @discardableResult
    public mutating func startTokenArrived(_ token: Data) -> Bool {
        let hex = Self.hex(token)
        guard hex != startToken else { return false }
        startToken = hex
        return true
    }

    /// The push token of activity `activityId` (`Activity.pushTokenUpdates`, or its `pushToken` read again): it is
    /// registered if none is, or if it is the registered one's new token; otherwise kept aside. Ignored for an
    /// activity that ended. Whether the registration changed.
    @discardableResult
    public mutating func activityTokenArrived(_ token: Data, activityId: String) -> Bool {
        guard !ended.contains(activityId) else { return false }
        let hex = Self.hex(token)
        guard self.activityId == nil || self.activityId == activityId else {
            others[activityId] = hex
            return false
        }
        guard hex != activityToken || activityId != self.activityId else { return false }
        self.activityId = activityId
        activityToken = hex
        others[activityId] = nil
        return true
    }

    /// Activity `activityId` ended or was dismissed (`activityStateUpdates`), or the app is ending it: its token is
    /// not taken any more. If it is the registered one, another running one whose token came takes its place (the
    /// smallest id), else nothing is registered. Whether the registration changed.
    @discardableResult
    public mutating func activityEnded(_ activityId: String) -> Bool {
        ended.insert(activityId)
        others[activityId] = nil
        guard activityId == self.activityId else { return false }
        if let next = others.keys.min(), let token = others.removeValue(forKey: next) {
            self.activityId = next
            activityToken = token
        } else {
            self.activityId = nil
            activityToken = nil
        }
        return true
    }

    /// Whether activity `activityId` is known to have ended (or to be ending).
    public func hasEnded(_ activityId: String) -> Bool {
        ended.contains(activityId)
    }

    /// The registration's Live Activity part. Off (the switch, or the system's setting for the app): `enabled = false`
    /// and no tokens, so the Mac neither starts one nor pushes to one.
    public func registration(enabled: Bool) -> ActivityRegistration {
        guard enabled else { return ActivityRegistration(enabled: false) }
        return ActivityRegistration(
            enabled: true, startToken: startToken, activityId: activityId, activityToken: activityToken
        )
    }

    /// An APNs token as lowercase hex.
    public static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}
