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

public struct DeviceRecord: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// SHA-256 (hex) of the device token; the token itself is never stored.
    public var tokenHash: String
    public var pairedAt: Int64
    public var lastSeen: Int64?

    public init(id: String, name: String, tokenHash: String, pairedAt: Int64, lastSeen: Int64? = nil) {
        self.id = id
        self.name = name
        self.tokenHash = tokenHash
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
    }
}

/// The paired phones, persisted as a 0600 JSON file.
public final class DeviceRegistry: @unchecked Sendable {
    /// The `deviceName` `critter-bridge-client` pairs under; only such a device may be revoked
    /// through the debug URL scheme.
    public static let devClientName = "critter-bridge-client"

    private let file: URL
    private let log: @Sendable (String) -> Void
    private let hash: @Sendable (String) -> String
    private let lock = NSLock()

    /// `log` hears about a devices file that had to be set aside (see `load`).
    public convenience init(file: URL, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(file: file, log: log, hash: { Hex.sha256(Data($0.utf8)) })
    }

    /// `hash` is how tokens are hashed; tests count its calls.
    init(file: URL, log: @escaping @Sendable (String) -> Void, hash: @escaping @Sendable (String) -> String) {
        self.file = file
        self.log = log
        self.hash = hash
    }

    public func list() -> [DeviceRecord] {
        lock.lock(); defer { lock.unlock() }
        return load() ?? []
    }

    public func add(name: String, now: Int64) throws -> (record: DeviceRecord, token: String) {
        lock.lock(); defer { lock.unlock() }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard let current = load() else { throw CocoaError(.fileReadCorruptFile) }
        let record = DeviceRecord(id: UUID().uuidString, name: name, tokenHash: hash(token), pairedAt: now)
        try save(current + [record])
        return (record, token)
    }

    /// The token is hashed and compared in constant time whether or not `deviceId` is known
    /// (against a stand-in hash when it isn't), so the time taken doesn't tell which ids exist.
    public func verify(deviceId: String, token: String) -> DeviceRecord? {
        lock.lock(); defer { lock.unlock() }
        let record = (load() ?? []).first(where: { $0.id == deviceId })
        let matches = Self.constantTimeEqual(hash(token), record?.tokenHash ?? Self.unknownDeviceHash)
        guard let record, matches else { return nil }
        return record
    }

    public func touch(deviceId: String, now: Int64) {
        update { $0.map { $0.id == deviceId ? DeviceRecord(id: $0.id, name: $0.name, tokenHash: $0.tokenHash, pairedAt: $0.pairedAt, lastSeen: now) : $0 } }
    }

    public func revoke(deviceId: String) {
        update { $0.filter { $0.id != deviceId } }
    }

    public func removeAll() {
        update { _ in [] }
    }

    private func update(_ transform: ([DeviceRecord]) -> [DeviceRecord]) {
        lock.lock(); defer { lock.unlock() }
        guard let current = load() else { return }
        try? save(transform(current))
    }

    /// The records on disk; none when there is no file yet. A file that can't be read or
    /// decoded is not taken for an empty list (the next save would overwrite it): it is renamed
    /// `devices.json.corrupt-<ms>` beside it, kept for a look, and logged, and the list starts
    /// empty. Nil only when it couldn't even be moved aside -- then nothing may be saved over it.
    private func load() -> [DeviceRecord]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        if let data = try? Data(contentsOf: file), let records = try? JSONDecoder().decode([DeviceRecord].self, from: data) {
            return records
        }
        let aside = file.deletingLastPathComponent()
            .appendingPathComponent("\(file.lastPathComponent).corrupt-\(Int64(Date().timeIntervalSince1970 * 1000))")
        do {
            try FileManager.default.moveItem(at: file, to: aside)
            log("bridge devices file unreadable, set aside as \(aside.lastPathComponent)")
            return []
        } catch {
            log("bridge devices file unreadable and not set aside: \(error)")
            return nil
        }
    }

    private func save(_ records: [DeviceRecord]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try atomicWrite(JSONEncoder().encode(records), to: file, permissions: 0o600)
    }

    /// What an unknown device's token is compared with: a SHA-256 hex's length, matched by none.
    private static let unknownDeviceHash = String(repeating: "-", count: 64)

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
