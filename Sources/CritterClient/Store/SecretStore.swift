import Foundation
import os

/// Where the phone keeps its secrets, one string per account: on iOS one service of the keychain group the app shares
/// with its notification service extension (spec §8.1), readable after the first unlock and on this device only.
public protocol SecretStore: Sendable {
    /// The secret under `account`; nil if there is none, or it cannot be read now.
    func secret(_ account: String) -> String?
    /// Saves `secret` under `account`, replacing what is there. Whether it was saved.
    func setSecret(_ secret: String, for account: String) -> Bool
    func removeSecret(_ account: String)
    /// The accounts there are secrets under; nil if that cannot be read now.
    func accounts() -> [String]?
}

extension SecretStore {
    /// Removes every secret but `kept`'s (all of them when nil).
    func removeSecrets(keeping kept: String?) {
        for account in accounts() ?? [] where account != kept {
            removeSecret(account)
        }
    }
}

/// Keeps `PushAck` in a `SecretStore`, as JSON under `account`: the registrations in it carry the push key, and the key
/// is only ever kept as a secret, never in a file (spec §10).
public final class SecretPushAckStorage: PushAckStorage {
    public static let account = "ack"
    private static let log = Logger(subsystem: "com.braynlabs.critter", category: "storage")
    private let secrets: any SecretStore

    public init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    public func loadPushAck() -> PushAck? {
        guard let text = secrets.secret(Self.account) else { return nil }
        return try? JSONDecoder().decode(PushAck.self, from: Data(text.utf8))
    }

    public func savePushAck(_ ack: PushAck?) {
        guard let ack else {
            secrets.removeSecret(Self.account)
            return
        }
        guard let data = try? JSONEncoder().encode(ack),
              secrets.setSecret(String(decoding: data, as: UTF8.self), for: Self.account)
        else {
            // Kept in memory by the store all the same: the next launch sends the registration once more.
            Self.log.error("keeping what the Mac confirmed of the push registration failed")
            return
        }
    }
}
