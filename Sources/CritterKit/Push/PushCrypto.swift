import CryptoKit
import Foundation

/// A notification's text: what the phone shows once it has opened the sealed field.
public struct PushText: Codable, Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var body: String

    public init(title: String, subtitle: String, body: String) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }
}

/// Seals notification text so it only appears in the push as ciphertext. AES-256-GCM; the key is
/// 32 random bytes the phone makes (base64url, no padding); a sealed string is the standard
/// base64 of CryptoKit's `combined` (12-byte nonce, ciphertext, 16-byte tag) of the JSON
/// `{"title":…,"subtitle":…,"body":…}`.
public enum PushCrypto {
    public static let keyByteCount = 32

    public enum Failure: Error, Equatable {
        case badKey
        case badCiphertext
    }

    /// A new key, as `PushRegistration.key` holds it.
    public static func makeKey() -> String {
        base64URL(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    /// The 32 bytes behind `key`, or nil if it is not base64url without padding of exactly 32 bytes.
    public static func keyData(_ key: String) -> Data? {
        guard key.utf8.allSatisfy({ isBase64URLCharacter($0) }) else { return nil }
        var standard = key.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: standard), data.count == keyByteCount else { return nil }
        return data
    }

    public static func seal(_ text: PushText, key: String) throws -> String {
        let symmetric = try symmetricKey(key)
        let plain = try encoder.encode(text)
        guard let combined = try AES.GCM.seal(plain, using: symmetric).combined else { throw Failure.badCiphertext }
        return combined.base64EncodedString()
    }

    public static func open(_ sealed: String, key: String) throws -> PushText {
        let symmetric = try symmetricKey(key)
        guard let combined = Data(base64Encoded: sealed) else { throw Failure.badCiphertext }
        let plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: symmetric)
        return try JSONDecoder().decode(PushText.self, from: plain)
    }

    private static func symmetricKey(_ key: String) throws -> SymmetricKey {
        guard let data = keyData(key) else { throw Failure.badKey }
        return SymmetricKey(data: data)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func isBase64URLCharacter(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
            return true
        default:
            return false
        }
    }
}
