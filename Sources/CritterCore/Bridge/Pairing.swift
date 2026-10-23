import Foundation

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
