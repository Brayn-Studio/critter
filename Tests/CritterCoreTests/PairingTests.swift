import Foundation
import Testing
@testable import CritterCore

@Test func pairingCodeShapeAndExpiry() {
    let code = PairingCode.generate(now: 1000)
    #expect(code.code.count == 8)
    #expect(code.code.allSatisfy { PairingCode.alphabet.contains($0) })
    #expect(code.expiresAt == 301_000)
}

@Test func pairingURIRoundTrip() {
    let fp = String(repeating: "ab12", count: 16)
    for host in ["192.168.1.5", "fe80::1"] {
        let uri = PairingURI(host: host, port: 47823, fingerprint: fp, code: "ABCD2345", name: "小明的 MacBook & 家")
        #expect(PairingURI(string: uri.string) == uri)
    }
    #expect(PairingURI(host: "fe80::1", port: 1, fingerprint: fp, code: "A", name: "n").string.hasPrefix("critter-pair://[fe80::1]:1?"))
    #expect(PairingURI(string: "http://x") == nil)
    #expect(PairingURI(string: "critter-pair://1.2.3.4:5?fp=zz&code=A&name=n") == nil)
}

/// The same text as the phone's manual-pairing dialog (Kotlin `fingerprintPrefixIsFourGroupsOfFour`).
@Test func pairingFingerprintPrefixIsFourGroupsOfFour() {
    #expect(PairingURI.fingerprintPrefix("0123456789abcdef" + String(repeating: "0", count: 48)) == "0123 4567 89ab cdef")
    let uri = PairingURI(host: "192.168.1.5", port: 1, fingerprint: String(repeating: "ab12", count: 16), code: "A", name: "n")
    #expect(uri.fingerprintPrefix == "ab12 ab12 ab12 ab12")
}

@Test func registryAddVerifyRevoke() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reg-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("devices.json")
    let registry = DeviceRegistry(file: file)
    let (record, token) = try registry.add(name: "Pixel", now: 5)
    #expect(registry.verify(deviceId: record.id, token: token)?.name == "Pixel")
    #expect(registry.verify(deviceId: record.id, token: token + "x") == nil)
    #expect(registry.verify(deviceId: "other", token: token) == nil)
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(!text.contains(token))
    let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(perms == 0o600)
    #expect(!token.contains("+") && !token.contains("/") && !token.contains("="))
    registry.touch(deviceId: record.id, now: 9)
    #expect(registry.list().first?.lastSeen == 9)
    registry.revoke(deviceId: record.id)
    #expect(registry.verify(deviceId: record.id, token: token) == nil)
    _ = try registry.add(name: "B", now: 6)
    registry.removeAll()
    #expect(registry.list().isEmpty)
}

/// A damaged devices file is not taken for an empty list and overwritten: it is set aside, kept
/// as it was, and the registry starts a new one.
@Test func corruptRegistryIsSetAside() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reg-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("devices.json")
    let damaged = Data(#"[{"id":"A","name":"Pixel","tokenHash":"#.utf8)
    try damaged.write(to: file)

    let registry = DeviceRegistry(file: file)
    let (record, token) = try registry.add(name: "Pixel 9", now: 5)
    #expect(registry.list().map(\.id) == [record.id])
    #expect(registry.verify(deviceId: record.id, token: token) != nil)
    let asides = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("devices.json.corrupt-") }
    #expect(asides.count == 1)
    #expect(try asides.first.map { try Data(contentsOf: dir.appendingPathComponent($0)) } == damaged)
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var all: [String] { lock.withLock { items } }
}

@Test func corruptRegistryIsLogged() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reg-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("devices.json")
    try Data("not json".utf8).write(to: file)
    let log = Recorder()
    let registry = DeviceRegistry(file: file, log: { log.add($0) })
    #expect(registry.list().isEmpty)
    #expect(log.all.count == 1)
    #expect(log.all.first?.contains("devices.json.corrupt-") == true)
    #expect(registry.list().isEmpty) // set aside once: nothing more to report
    #expect(log.all.count == 1)
}

/// Whether the id is known or not, `verify` hashes the token once and compares it in constant
/// time -- so how long it takes doesn't tell which device ids exist.
@Test func unknownIdStillHashes() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reg-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let hashed = Recorder()
    let registry = DeviceRegistry(file: dir.appendingPathComponent("devices.json"), log: { _ in }, hash: { token in
        hashed.add(token)
        return Hex.sha256(Data(token.utf8))
    })
    let (record, token) = try registry.add(name: "Pixel", now: 5)
    let before = hashed.all.count
    #expect(registry.verify(deviceId: "no-such-device", token: token) == nil)
    #expect(hashed.all.count == before + 1)
    #expect(registry.verify(deviceId: record.id, token: token)?.id == record.id)
    #expect(hashed.all.count == before + 2)
}

/// A phone's name comes off the network: one line, at most 64 characters, never empty.
@Test func deviceNameIsClampedToOneShortLine() {
    #expect(BridgeProtocol.deviceName("Pixel 9") == "Pixel 9")
    #expect(BridgeProtocol.deviceName(String(repeating: "长", count: 1_000)) == String(repeating: "长", count: 64))
    #expect(BridgeProtocol.deviceName("  a\nb\tc\u{0}d  ") == "a b c d")
    #expect(BridgeProtocol.deviceName(" \n ") == "手机")
    #expect(BridgeProtocol.deviceName(DeviceRegistry.devClientName) == DeviceRegistry.devClientName)
}
