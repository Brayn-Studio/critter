import Foundation

/// "登录时自动启动": a per-user launchd agent that runs `open -g -a <Clawd.app>` once at
/// login (`RunAtLoad`). Writing the plist into `~/Library/LaunchAgents` turns it on from
/// the next login; deleting it turns it off. Directories are parameters so tests never
/// touch the real one.
public enum LaunchAgent {
    public static let label = "local.clawd.pet"

    /// The agent's XML property list.
    public static func plist(appPath: String) -> Data {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-g", "-a", appPath],
            "RunAtLoad": true,
        ]
        // A dictionary of strings, a string array and a bool always serializes.
        return try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    /// `~/Library/LaunchAgents` for the user whose home is `home`.
    public static func userLaunchAgentsDir(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        home.appendingPathComponent("Library").appendingPathComponent("LaunchAgents")
    }

    public static func plistURL(in launchAgentsDir: URL) -> URL {
        launchAgentsDir.appendingPathComponent("\(label).plist")
    }

    public static func isInstalled(in launchAgentsDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: plistURL(in: launchAgentsDir).path)
    }

    /// Writes (or rewrites, e.g. after the app moved) the agent's plist, atomically.
    public static func install(appPath: String, in launchAgentsDir: URL) throws {
        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        try plist(appPath: appPath).write(to: plistURL(in: launchAgentsDir), options: .atomic)
    }

    /// Deletes the agent's plist; a plist that is already gone is not an error.
    public static func remove(in launchAgentsDir: URL) throws {
        do {
            try FileManager.default.removeItem(at: plistURL(in: launchAgentsDir))
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}
