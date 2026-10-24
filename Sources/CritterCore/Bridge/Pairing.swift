import Foundation

public struct DeviceRecord: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// SHA-256 (hex) of the device token; the token itself is never stored.
    public var tokenHash: String
    public var pairedAt: Int64
    public var lastSeen: Int64?
    /// How to push to this phone (an iPhone that registered). Added later: absent in older files.
    public var push: PushRegistration?
    /// The Mac's own, not the phone's: when it push-to-started a Live Activity on this phone whose token has
    /// not arrived yet (`LiveActivityPlanner.unconfirmedStartAt`), so a restart does not start a second one.
    /// Goes with the registration.
    public var unconfirmedActivityStart: Int64?

    public init(
        id: String, name: String, tokenHash: String, pairedAt: Int64, lastSeen: Int64? = nil, push: PushRegistration? = nil,
        unconfirmedActivityStart: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.tokenHash = tokenHash
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
        self.push = push
        self.unconfirmedActivityStart = unconfirmedActivityStart
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, tokenHash, pairedAt, lastSeen, push, unconfirmedActivityStart
    }

    /// A push registration this build cannot read (a value from a newer build, a field missing) is left out,
    /// not the device: one bad registration must not make the whole file unreadable and unpair every phone.
    /// The phone registers again the next time it connects.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        tokenHash = try container.decode(String.self, forKey: .tokenHash)
        pairedAt = try container.decode(Int64.self, forKey: .pairedAt)
        lastSeen = try container.decodeIfPresent(Int64.self, forKey: .lastSeen)
        push = (try? container.decodeIfPresent(PushRegistration.self, forKey: .push)) ?? nil
        unconfirmedActivityStart = push == nil ? nil : (try? container.decodeIfPresent(Int64.self, forKey: .unconfirmedActivityStart)) ?? nil
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
    /// Devices whose unreadable push registration has been logged (under `lock`).
    private var reportedUnreadablePush: Set<String> = []

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
        change(deviceId) { $0.lastSeen = now }
    }

    /// Keeps `registration` as this device's push registration, replacing any earlier one; an
    /// empty registration (see `PushRegistration.isEmpty`) removes it instead. False if there is
    /// no such device or the file could not be written.
    ///
    /// A registration that shares a token with another device's (the same phone paired again before its old
    /// registration was taken back) takes it over: the other device's registration goes, in the same write,
    /// so nothing is pushed twice.
    @discardableResult
    public func setPush(deviceId: String, _ registration: PushRegistration) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var records = load(), let index = records.firstIndex(where: { $0.id == deviceId }) else { return false }
        let before = records
        records[index].push = registration.isEmpty ? nil : registration
        if registration.isEmpty { records[index].unconfirmedActivityStart = nil }
        if !registration.isEmpty {
            let tokens = PushCoordinatorRules.tokens(of: registration)
            for other in records.indices where other != index {
                guard let theirs = records[other].push, !PushCoordinatorRules.tokens(of: theirs).isDisjoint(with: tokens) else { continue }
                records[other].push = nil
                records[other].unconfirmedActivityStart = nil
                log("bridge device \(records[other].id.prefix(8)): push registration taken over by \(deviceId.prefix(8))")
            }
        }
        guard records != before else { return true }
        return (try? save(records)) != nil
    }


    /// APNs said the device token is no good (the app was deleted): forgets the whole
    /// registration, for the phone to make a new one. False if the file could not be written.
    @discardableResult
    public func dropPushToken(deviceId: String) -> Bool {
        change(deviceId) {
            $0.push = nil
            $0.unconfirmedActivityStart = nil
        }
    }

    /// Keeps (or, with nil, clears) when the Mac push-to-started a Live Activity whose token has not come yet.
    /// Does nothing for a device without a registration. False if the file could not be written.
    @discardableResult
    public func setUnconfirmedActivityStart(deviceId: String, at time: Int64?) -> Bool {
        change(deviceId) {
            guard $0.push != nil else { return }
            $0.unconfirmedActivityStart = time
        }
    }

    /// Sets (or, with nil, clears) the running Live Activity's id and push token. Does nothing
    /// for a device without a registration or without a Live Activity part. False if the file could not be
    /// written.
    @discardableResult
    public func setActivity(deviceId: String, activityId: String?, activityToken: String?) -> Bool {
        change(deviceId) {
            guard $0.push?.activity != nil else { return }
            $0.push?.activity?.activityId = activityId
            $0.push?.activity?.activityToken = activityToken
        }
    }

    /// The devices that have a push registration.
    public func pushDevices() -> [DeviceRecord] {
        list().filter { $0.push != nil }
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

    /// Edits one device's record in place. Nothing is written when `edit` changes nothing.
    /// False if there is no such device or the file could not be written.
    @discardableResult
    private func change(_ deviceId: String, _ edit: (inout DeviceRecord) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var records = load(), let index = records.firstIndex(where: { $0.id == deviceId }) else { return false }
        let before = records[index]
        edit(&records[index])
        guard records[index] != before else { return true }
        return (try? save(records)) != nil
    }

    /// The records on disk; none when there is no file yet. A file that can't be read or
    /// decoded is not taken for an empty list (the next save would overwrite it): it is renamed
    /// `devices.json.corrupt-<ms>` beside it, kept for a look, and logged, and the list starts
    /// empty. Nil only when it couldn't even be moved aside -- then nothing may be saved over it.
    private func load() -> [DeviceRecord]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        if let data = try? Data(contentsOf: file), let records = try? JSONDecoder().decode([DeviceRecord].self, from: data) {
            reportUnreadablePushes(records, in: data)
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

    /// Logs, once per device, a push registration on disk that `DeviceRecord` had to leave out.
    private func reportUnreadablePushes(_ records: [DeviceRecord], in data: Data) {
        // Cheap test first: most files have no registration at all.
        guard records.contains(where: { $0.push == nil }), data.range(of: Data("\"push\"".utf8)) != nil,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], raw.count == records.count
        else { return }
        for (record, object) in zip(records, raw) where record.push == nil && !reportedUnreadablePush.contains(record.id) {
            guard let value = object["push"], !(value is NSNull) else { continue }
            reportedUnreadablePush.insert(record.id)
            log("bridge device \(record.id.prefix(8)): push registration unreadable, left out")
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
