import Foundation
import Testing
@testable import ClawdCore

@Test func launchAgentPlist() throws {
    let obj = try PropertyListSerialization.propertyList(from: LaunchAgent.plist(appPath: "/Users/u/Applications/Clawd.app"), format: nil) as! [String: Any]
    #expect(obj["Label"] as? String == "local.clawd.pet")
    #expect(obj["ProgramArguments"] as? [String] == ["/usr/bin/open", "-g", "-a", "/Users/u/Applications/Clawd.app"])
    #expect(obj["RunAtLoad"] as? Bool == true)
}

@Test func launchAgentPlistIsXML() {
    let text = String(decoding: LaunchAgent.plist(appPath: "/A/Clawd.app"), as: UTF8.self)
    #expect(text.hasPrefix("<?xml"))
    #expect(text.contains("<string>/A/Clawd.app</string>"))
}

@Test func launchAgentInstallsAndRemovesItsFileInADirectory() throws {
    // A temp stand-in for ~/Library/LaunchAgents, which doesn't exist yet.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("clawd-launchagent-tests-\(UUID().uuidString)")
        .appendingPathComponent("LaunchAgents")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    let file = LaunchAgent.plistURL(in: dir)
    #expect(file.lastPathComponent == "local.clawd.pet.plist")
    #expect(!LaunchAgent.isInstalled(in: dir))

    try LaunchAgent.install(appPath: "/old/Clawd.app", in: dir)
    #expect(LaunchAgent.isInstalled(in: dir))
    try LaunchAgent.install(appPath: "/new/Clawd.app", in: dir)
    #expect(try Data(contentsOf: file) == LaunchAgent.plist(appPath: "/new/Clawd.app"))

    try LaunchAgent.remove(in: dir)
    #expect(!LaunchAgent.isInstalled(in: dir))
    try LaunchAgent.remove(in: dir) // already gone: not an error
}

@Test func launchAgentsDirIsInTheUsersLibrary() {
    #expect(LaunchAgent.userLaunchAgentsDir(home: URL(fileURLWithPath: "/Users/u")).path == "/Users/u/Library/LaunchAgents")
}
