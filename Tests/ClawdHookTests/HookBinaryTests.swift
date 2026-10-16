import ClawdCore
import Foundation
import Testing

private enum TestSetupError: Error {
    case productsDirectoryNotFound
    case binaryNotFound(String)
}

/// Locates the directory holding this test run's build products (where `clawd-hook` and
/// the test bundle itself both land), so the test can exec the real built binary.
///
/// Swift Testing under `swift test` runs as `swiftpm-testing-helper`, not as a loaded
/// `.xctest` bundle, so `Bundle.main`/`Bundle.allBundles` point at the toolchain rather
/// than the build products -- there is no `.xctest` bundle for `Bundle.allBundles` to find.
/// What *is* available is `--test-bundle-path <dir>/Contents/MacOS/<name>` among
/// `CommandLine.arguments`, so we walk up from any argument until we find the `.xctest`
/// bundle directory and take its parent, which is the same directory `clawd-hook` is in
/// (because `ClawdHookTests` depends on the `clawd-hook` product).
private func productsDirectory() throws -> URL {
    for argument in CommandLine.arguments {
        var current = URL(fileURLWithPath: argument)
        while current.pathComponents.count > 1 {
            if current.lastPathComponent.hasSuffix(".xctest") {
                return current.deletingLastPathComponent()
            }
            current = current.deletingLastPathComponent()
        }
    }
    throw TestSetupError.productsDirectoryNotFound
}

private func clawdHookBinaryURL() throws -> URL {
    let binary = try productsDirectory().appendingPathComponent("clawd-hook")
    guard FileManager.default.fileExists(atPath: binary.path) else {
        throw TestSetupError.binaryNotFound(binary.path)
    }
    return binary
}

/// Runs the actual built `clawd-hook` executable as a subprocess, exercising the full path
/// from `main.swift` down through `HookCommand`, end to end.
@Test func binarySmoke() throws {
    let binary = try clawdHookBinaryURL()

    let base = FileManager.default.temporaryDirectory.appendingPathComponent("clawd-hook-binary-\(UUID().uuidString)")
    let clawdHome = base.appendingPathComponent(".clawd")
    let claudeHome = base.appendingPathComponent(".claude")

    let process = Process()
    process.executableURL = binary
    process.arguments = ["event"]
    process.environment = [
        "CLAWD_HOME": clawdHome.path,
        "CLAUDE_CONFIG_DIR": claudeHome.path,
        "HOME": base.path,
    ]

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe

    try process.run()
    let payload = #"{"session_id":"t1","cwd":"/x","hook_event_name":"Stop","last_assistant_message":"全部完成。"}"#
    stdinPipe.fileHandleForWriting.write(Data(payload.utf8))
    try stdinPipe.fileHandleForWriting.close()

    process.waitUntilExit()

    let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    #expect(process.terminationStatus == 0)
    #expect(outputData.isEmpty)

    let stateFile = clawdHome.appendingPathComponent("sessions").appendingPathComponent("t1.json")
    let data = try Data(contentsOf: stateFile)
    let record = try JSONDecoder().decode(SessionRecord.self, from: data)
    #expect(record.state == .done)
}
