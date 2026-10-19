import CryptoKit
import Foundation

/// Lowercase hex digests: match keys, device token hashes and certificate fingerprints.
public enum Hex {
    /// SHA-256 of `data` as 64 lowercase hex digits.
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
