import Foundation
import Testing
@testable import CritterCore

private let key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

private func push(token: String = "aa11", key: String = key, activity: ActivityRegistration? = nil) -> PushRegistration {
    PushRegistration(
        token: token, environment: .sandbox, bundleId: "com.braynlabs.critter", key: key,
        notifyDone: true, notifyError: true, activity: activity
    )
}

private let activity = ActivityRegistration(enabled: true, startToken: "5a5a", activityId: "A1", activityToken: "9f9f")

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("reg-\(UUID().uuidString)").appendingPathComponent("devices.json")
}

private func permissions(_ file: URL) throws -> Int? {
    try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
}

/// A devices file from before push registration has no `push` key.
@Test func oldDevicesFileStillDecodes() throws {
    let file = tempFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"[{"id":"D1","lastSeen":9,"name":"Pixel","pairedAt":5,"tokenHash":"abc"}]"#.utf8).write(to: file)

    let registry = DeviceRegistry(file: file)
    let devices = registry.list()
    #expect(devices.map(\.id) == ["D1"])
    #expect(devices.first?.push == nil)
    #expect(registry.pushDevices().isEmpty)
    // And it is not set aside as damaged.
    #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["devices.json"])
}

@Test func pushRegistrationIsStoredAndReplaced() throws {
    let file = tempFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let registry = DeviceRegistry(file: file)
    let (a, tokenA) = try registry.add(name: "iPhone", now: 5)
    let (b, _) = try registry.add(name: "Pixel", now: 6)

    #expect(registry.setPush(deviceId: a.id, push(activity: activity)))
    #expect(registry.list().first { $0.id == a.id }?.push == push(activity: activity))
    #expect(registry.list().first { $0.id == b.id }?.push == nil)
    #expect(registry.pushDevices().map(\.id) == [a.id])

    // A new registration replaces the old one whole: the activity part goes with it.
    #expect(registry.setPush(deviceId: a.id, push(token: "bb22")))
    #expect(registry.list().first { $0.id == a.id }?.push == push(token: "bb22"))

    // It survives a new registry on the same file, and the pairing is untouched.
    let reopened = DeviceRegistry(file: file)
    #expect(reopened.pushDevices().first?.push?.token == "bb22")
    #expect(reopened.verify(deviceId: a.id, token: tokenA)?.name == "iPhone")

    // A device the Mac does not know cannot register.
    #expect(!registry.setPush(deviceId: "nobody", push()))
    #expect(registry.pushDevices().map(\.id) == [a.id])
}

@Test func touchKeepsThePushRegistration() throws {
    let file = tempFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let registry = DeviceRegistry(file: file)
    let (record, _) = try registry.add(name: "iPhone", now: 5)
    registry.setPush(deviceId: record.id, push(activity: activity))
    registry.touch(deviceId: record.id, now: 99)
    let device = registry.list().first
    #expect(device?.lastSeen == 99)
    #expect(device?.push == push(activity: activity))
}

@Test func anEmptyRegistrationClearsIt() throws {
    let file = tempFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let registry = DeviceRegistry(file: file)
    let (record, _) = try registry.add(name: "iPhone", now: 5)

    registry.setPush(deviceId: record.id, push())
    #expect(registry.setPush(deviceId: record.id, push(token: "")))
    #expect(registry.list().first?.push == nil)
    #expect(registry.pushDevices().isEmpty)
    #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("\"push\""))

    // A key that is not 32 bytes is as good as none.
    registry.setPush(deviceId: record.id, push())
    registry.setPush(deviceId: record.id, push(key: "short"))
    #expect(registry.list().first?.push == nil)
}

@Test func droppingTheTokenDeletesTheWholeRegistration() throws {
    let file = tempFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let registry = DeviceRegistry(file: file)
    let (a, _) = try registry.add(name: "iPhone", now: 5)
    let (b, _) = try registry.add(name: "iPad", now: 6)
    registry.setPush(deviceId: a.id, push(activity: activity))
    registry.setPush(deviceId: b.id, push(token: "cc33"))
    registry.dropPushToken(deviceId: a.id)
    #expect(registry.pushDevices().map(\.id) == [b.id])
    #expect(registry.list().count == 2)
}

@Test func theActivityCanBeClearedAndSet() throws {
    let file = tempFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let registry = DeviceRegistry(file: file)
    let (record, _) = try registry.add(name: "iPhone", now: 5)
    registry.setPush(deviceId: record.id, push(activity: activity))

    registry.setActivity(deviceId: record.id, activityId: nil, activityToken: nil)
    #expect(registry.list().first?.push?.activity == ActivityRegistration(enabled: true, startToken: "5a5a"))
    #expect(registry.list().first?.push?.token == "aa11")

    registry.setActivity(deviceId: record.id, activityId: "A2", activityToken: "1234")
    #expect(registry.list().first?.push?.activity == ActivityRegistration(enabled: true, startToken: "5a5a", activityId: "A2", activityToken: "1234"))

    // Nothing to change where there is no registration, or no activity part.
    registry.setActivity(deviceId: "nobody", activityId: nil, activityToken: nil)
    registry.setPush(deviceId: record.id, push())
    registry.setActivity(deviceId: record.id, activityId: "A3", activityToken: "5678")
    #expect(registry.list().first?.push == push())
    registry.dropPushToken(deviceId: record.id)
    registry.setActivity(deviceId: record.id, activityId: "A3", activityToken: "5678")
    #expect(registry.list().first?.push == nil)
}

@Test func revokeAndResetDropTheRegistration() throws {
    let file = tempFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let registry = DeviceRegistry(file: file)
    let (a, _) = try registry.add(name: "iPhone", now: 5)
    let (b, _) = try registry.add(name: "iPad", now: 6)
    registry.setPush(deviceId: a.id, push(token: "aa11"))
    registry.setPush(deviceId: b.id, push(token: "bb22"))

    registry.revoke(deviceId: a.id)
    #expect(registry.pushDevices().map(\.id) == [b.id])
    var text = try String(contentsOf: file, encoding: .utf8)
    #expect(!text.contains("aa11") && text.contains("bb22"))

    registry.removeAll()
    #expect(registry.pushDevices().isEmpty)
    text = try String(contentsOf: file, encoding: .utf8)
    #expect(!text.contains("bb22") && !text.contains(key))
}

@Test func devicesFileStaysPrivate() throws {
    let file = tempFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let registry = DeviceRegistry(file: file)
    let (record, _) = try registry.add(name: "iPhone", now: 5)
    // The file holds the push key now; even one left more open by hand is closed by the next write.
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    registry.setPush(deviceId: record.id, push())
    #expect(try permissions(file) == 0o600)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    registry.setActivity(deviceId: record.id, activityId: nil, activityToken: nil)
    registry.dropPushToken(deviceId: record.id)
    #expect(try permissions(file) == 0o600)
}

@Test func registeringTheSameThingAgainWritesNothing() throws {
    let file = tempFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let registry = DeviceRegistry(file: file)
    let (record, _) = try registry.add(name: "iPhone", now: 5)
    registry.setPush(deviceId: record.id, push())
    let before = try Data(contentsOf: file)
    try FileManager.default.removeItem(at: file)
    try before.write(to: file)
    let marker = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
    #expect(registry.setPush(deviceId: record.id, push()))
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int == marker)
}
