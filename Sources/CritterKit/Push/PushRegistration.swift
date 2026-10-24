import Foundation

public enum PushEnvironment: String, Codable, Sendable {
    case sandbox, production
}

/// The Live Activity part of a push registration.
public struct ActivityRegistration: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// The push-to-start token, lowercase hex.
    public var startToken: String?
    /// The running Live Activity's id, and the token that updates it (lowercase hex).
    public var activityId: String?
    public var activityToken: String?

    public init(enabled: Bool, startToken: String? = nil, activityId: String? = nil, activityToken: String? = nil) {
        self.enabled = enabled
        self.startToken = startToken
        self.activityId = activityId
        self.activityToken = activityToken
    }
}

/// What an iPhone tells the Mac so the Mac can push to it: the `registration` of a `push` frame.
/// Every registration is complete and replaces the old one; an empty token takes it back.
/// `docs/critter-bridge-protocol.md` has the wire format.
public struct PushRegistration: Codable, Equatable, Sendable {
    /// The APNs device token, lowercase hex. Empty means "unregister".
    public var token: String
    public var environment: PushEnvironment
    public var bundleId: String
    /// The key that seals notification text (`PushCrypto`): 32 bytes, base64url without padding.
    public var key: String
    public var notifyDone: Bool
    public var notifyError: Bool
    public var activity: ActivityRegistration?

    public init(
        token: String, environment: PushEnvironment, bundleId: String, key: String,
        notifyDone: Bool, notifyError: Bool, activity: ActivityRegistration? = nil
    ) {
        self.token = token
        self.environment = environment
        self.bundleId = bundleId
        self.key = key
        self.notifyDone = notifyDone
        self.notifyError = notifyError
        self.activity = activity
    }

    /// `key` decodes to exactly 32 bytes.
    public var hasValidKey: Bool { PushCrypto.keyData(key) != nil }

    /// Nothing to push to: no token, or a key nothing could be sealed with.
    public var isEmpty: Bool { token.isEmpty || !hasValidKey }

    /// `token`, and the Live Activity's `startToken` and `activityToken` where they are given (not empty), are
    /// lowercase ASCII hex, as APNs tokens are written.
    public var hasValidTokens: Bool {
        [token, activity?.startToken, activity?.activityToken].compactMap { $0 }.allSatisfy { token in
            token.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
        }
    }
}
