import CritterKit
import Foundation

/// Certificate pinning: the Mac's certificate is trusted only if the SHA-256 of its DER is
/// exactly the fingerprint from pairing (64 lowercase hex digits; no CA chain is checked).
public enum PinnedCertificate {
    public static func fingerprint(der: Data) -> String {
        Hex.sha256(der)
    }

    public static func matches(der: Data, fingerprint: String) -> Bool {
        Self.fingerprint(der: der) == fingerprint
    }
}
