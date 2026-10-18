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

/// A phone's name comes off the network: one line, at most 64 characters, never empty.
@Test func deviceNameIsClampedToOneShortLine() {
    #expect(BridgeProtocol.deviceName("Pixel 9") == "Pixel 9")
    #expect(BridgeProtocol.deviceName(String(repeating: "长", count: 1_000)) == String(repeating: "长", count: 64))
    #expect(BridgeProtocol.deviceName("  a\nb\tc\u{0}d  ") == "a b c d")
    #expect(BridgeProtocol.deviceName(" \n ") == "手机")
    #expect(BridgeProtocol.deviceName(DeviceRegistry.devClientName) == DeviceRegistry.devClientName)
}
