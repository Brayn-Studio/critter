import Foundation

/// What the Mac needs to talk to APNs with a token (`.p8`) key, set up in the settings' "iPhone 推送".
public struct APNsConfig: Equatable, Sendable {
    /// The app's bundle id; the default is the phone app's.
    public static let defaultBundleId = "com.braynlabs.critter"

    /// The key's id, 10 characters, as in `AuthKey_<KeyID>.p8`.
    public var keyId: String
    public var teamId: String
    public var bundleId: String
    /// Where the `.p8` is kept: `~/.critter/bridge/apns/`.
    public var keyFile: URL

    public init(keyId: String, teamId: String, bundleId: String = Self.defaultBundleId, keyFile: URL) {
        self.keyId = keyId
        self.teamId = teamId
        self.bundleId = bundleId
        self.keyFile = keyFile
    }

    /// The Key ID in a file name Apple gave the key: "AuthKey_ABC123DEFG.p8" -> "ABC123DEFG". Nil for any other
    /// name; the user types the id then.
    public static func keyId(fromFileName name: String) -> String? {
        let prefix = "AuthKey_"
        let suffix = ".p8"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else { return nil }
        let id = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } ? id : nil
    }
}

/// What the settings' "iPhone 推送" amounts to: nothing set up yet, a setup ready to sign with, or a setup that
/// cannot work and why (for the status line). Printed, it never shows the key.
public enum APNsSetup: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The reason shown when the `.p8` is missing or is not a P-256 key.
    public static let unreadableKey = "读不了 .p8 文件"

    case notConfigured
    /// `pem` is the `.p8`'s contents; it is never logged.
    case ready(APNsConfig, pem: String)
    case problem(String)
}

extension APNsSetup {
    public var description: String {
        switch self {
        case .notConfigured:
            return "notConfigured"
        case .ready(let config, _):
            return "ready(keyId: \(config.keyId), teamId: \(config.teamId), bundleId: \(config.bundleId), "
                + "keyFile: \(config.keyFile.lastPathComponent), pem: <hidden>)"
        case .problem(let reason):
            return "problem(\(reason))"
        }
    }

    public var debugDescription: String { description }
}
