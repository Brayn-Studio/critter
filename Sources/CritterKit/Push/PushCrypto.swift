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
/// `{"title":…,"subtitle":…,"body":…}`. The text is bound to the push it travels in: its category,
/// request id and session id are the associated data (`associatedData`), so a sealed text moved into
/// another push does not open.
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

    /// The protocol doc's test vector key, bytes 0...31: public, so nothing sealed with it is secret. The simulator's
    /// DEBUG builds take it as the push key for one run (`-critterTestPushKey`, with `scripts/dev/push-payloads/make.sh`);
    /// the app replaces it when it finds it kept (`isTestVectorKey`).
    public static let testVectorKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    /// Whether `key` is `testVectorKey` (its bytes are, however they are written).
    public static func isTestVectorKey(_ key: String) -> Bool {
        keyData(key) == Data(0..<UInt8(keyByteCount))
    }

    /// The 32 bytes behind `key`, or nil if it is not base64url without padding of exactly 32 bytes.
    public static func keyData(_ key: String) -> Data? {
        guard key.utf8.allSatisfy({ isBase64URLCharacter($0) }) else { return nil }
        var standard = key.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: standard), data.count == keyByteCount else { return nil }
        return data
    }

    /// The associated data of a push's sealed text: the UTF-8 of `<k>|<r>|<s>` -- its category, its
    /// request id (empty when it has none) and its session id, as the payload's `k`, `r` and `s` hold them.
    public static func associatedData(category: PushCategory, requestId: String?, sessionId: String) -> Data {
        Data("\(category.rawValue)|\(requestId ?? "")|\(sessionId)".utf8)
    }

    /// Seals `text` for the push with this category, request id and session id.
    public static func seal(
        _ text: PushText, key: String, category: PushCategory, requestId: String?, sessionId: String
    ) throws -> String {
        let symmetric = try symmetricKey(key)
        let plain = try encoder.encode(text)
        let bound = associatedData(category: category, requestId: requestId, sessionId: sessionId)
        guard let combined = try AES.GCM.seal(plain, using: symmetric, authenticating: bound).combined else {
            throw Failure.badCiphertext
        }
        return combined.base64EncodedString()
    }

    /// Opens a text sealed for the push with this category, request id and session id; throws for any other.
    public static func open(
        _ sealed: String, key: String, category: PushCategory, requestId: String?, sessionId: String
    ) throws -> PushText {
        let symmetric = try symmetricKey(key)
        guard let combined = Data(base64Encoded: sealed) else { throw Failure.badCiphertext }
        let bound = associatedData(category: category, requestId: requestId, sessionId: sessionId)
        let plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: symmetric, authenticating: bound)
        return try JSONDecoder().decode(PushText.self, from: plain)
    }

    /// Opens the sealed text of a push the phone received.
    public static func open(_ alert: ParsedPush.Alert, key: String) throws -> PushText {
        try open(alert.sealed, key: key, category: alert.category, requestId: alert.requestId, sessionId: alert.sessionId)
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
