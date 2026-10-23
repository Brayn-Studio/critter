import Foundation

/// A short-lived, single-use code the user types (or scans) on the phone to pair it.
public struct PairingCode: Equatable, Sendable {
    public let code: String
    public let expiresAt: Int64

    public static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    public static let length = 8
    public static let lifetimeMs: Int64 = 300_000

    public init(code: String, expiresAt: Int64) {
        self.code = code
        self.expiresAt = expiresAt
    }

    public static func generate(now: Int64) -> PairingCode {
        var rng = SystemRandomNumberGenerator()
        let code = String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
        return PairingCode(code: code, expiresAt: now + lifetimeMs)
    }
}

/// `critter-pair://<host>:<port>?fp=<sha256 of the cert DER, lowercase hex>&code=<code>&name=<escaped>`
/// as shown in the pairing QR code. IPv6 hosts are bracketed.
public struct PairingURI: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var fingerprint: String
    public var code: String
    public var name: String

    public init(host: String, port: UInt16, fingerprint: String, code: String, name: String) {
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        self.code = code
        self.name = name
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The first 16 hex characters of the fingerprint in groups of four ("0123 4567 89ab cdef"),
    /// shown under the code in the "添加手机" sheet. A phone pairing without the QR code shows the
    /// same text (Kotlin `PairingUri.fingerprintPrefix`) and asks the user to compare the two.
    public var fingerprintPrefix: String { Self.fingerprintPrefix(fingerprint) }

    public static func fingerprintPrefix(_ fingerprint: String) -> String {
        let head = Array(fingerprint.prefix(16))
        return stride(from: 0, to: head.count, by: 4)
            .map { String(head[$0..<min($0 + 4, head.count)]) }
            .joined(separator: " ")
    }

    public var string: String {
        let h = host.contains(":") ? "[\(host)]" : host
        let escaped = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? s }
        return "critter-pair://\(h):\(port)?fp=\(escaped(fingerprint))&code=\(escaped(code))&name=\(escaped(name))"
    }

    public init?(string: String) {
        guard let c = URLComponents(string: string), c.scheme == "critter-pair",
              var host = c.host, !host.isEmpty, let port = c.port, (1...65535).contains(port),
              let items = c.queryItems else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        func value(_ k: String) -> String? { items.first { $0.name == k }?.value }
        guard let fp = value("fp"), fp.count == 64,
              fp.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let code = value("code"), !code.isEmpty, let name = value("name") else { return nil }
        self.init(host: host, port: UInt16(port), fingerprint: fp, code: code, name: name)
    }
}
