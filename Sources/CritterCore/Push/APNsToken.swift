import CryptoKit
import Foundation

/// The provider token APNs wants with every push: an ES256 JWT signed with the team's `.p8` key. Made once and
/// reused for 50 minutes (APNs refuses a token over an hour old, and one renewed more than every 20 minutes).
///
/// Not thread-safe: one caller (the bridge queue). The `.p8` and the JWT are never logged.
public final class APNsToken {
    public enum Failure: Error, Equatable {
        /// Not a P-256 private key in PEM (the `.p8` of an APNs key is PKCS #8).
        case unreadableKey
    }

    /// How long a JWT is reused.
    public static let lifetime: TimeInterval = 50 * 60

    private let config: APNsConfig
    private let key: P256.Signing.PrivateKey
    private var issuedAt: Date?
    private var jwt: String?

    /// - Parameter pem: the contents of the `.p8` file.
    public init(config: APNsConfig, pem: String) throws {
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { throw Failure.unreadableKey }
        self.config = config
        self.key = key
    }

    /// The JWT to put after "bearer ", signed now or up to 50 minutes ago.
    public func bearer(now: Date) throws -> String {
        if let jwt, let issuedAt, now >= issuedAt, now.timeIntervalSince(issuedAt) < Self.lifetime { return jwt }
        let header = try Self.json(["alg": "ES256", "kid": config.keyId])
        let claims = try Self.json(["iss": config.teamId, "iat": Int(now.timeIntervalSince1970)])
        let signingInput = "\(Self.base64URL(header)).\(Self.base64URL(claims))"
        // ES256 is the raw r || s, not DER.
        let signature = try key.signature(for: Data(signingInput.utf8)).rawRepresentation
        let token = "\(signingInput).\(Self.base64URL(signature))"
        jwt = token
        issuedAt = now
        return token
    }

    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
