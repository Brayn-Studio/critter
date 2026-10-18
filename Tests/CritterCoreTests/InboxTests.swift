import Foundation
import Testing
@testable import CritterCore
#if canImport(Darwin)
import Darwin
#endif

private func tmpEnv() -> (paths: CritterPaths, env: [String: String]) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("critter-inbox-tests-\(UUID().uuidString)")
    let critterHome = base.appendingPathComponent(".critter")
    let claudeHome = base.appendingPathComponent(".claude")
    let env = ["CRITTER_HOME": critterHome.path, "CLAUDE_CONFIG_DIR": claudeHome.path, "HOME": base.path]
    return (CritterPaths(critterHome: critterHome, claudeHome: claudeHome), env)
}

private func fire(_ event: String, session: String = "s1", env: [String: String]) {
    let root: [String: Any] = ["session_id": session, "cwd": "/x", "hook_event_name": event]
    _ = HookCommand.run(
        arguments: ["event"], stdin: try! JSONSerialization.data(withJSONObject: root), environment: env,
        now: 1000, hookParentPid: 1, launcher: FakeLauncher()
    )
}

private func permissions(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
}

@Test func sessionStartWritesInboxFromEnvironment() {
    var (paths, env) = tmpEnv()
    env["CLAUDE_CODE_MESSAGING_SOCKET"] = "/tmp/cc-socks/abc.sock"
    env["CLAUDE_CODE_MESSAGING_TOKEN"] = "tok"
    fire("SessionStart", env: env)
    #expect(InboxStore(paths: paths).read(sessionId: "s1") == InboxRecord(sessionId: "s1", socketPath: "/tmp/cc-socks/abc.sock", token: "tok"))
    #expect(permissions(paths.inboxDir.appendingPathComponent("s1.json")) == 0o600)
    #expect(permissions(paths.inboxDir) == 0o700)
}

@Test func sessionStartWithoutEnvironmentWritesNothing() {
    var (paths, env) = tmpEnv()
    fire("SessionStart", env: env)
    env["CLAUDE_CODE_MESSAGING_SOCKET"] = "/tmp/cc-socks/abc.sock"
    env["CLAUDE_CODE_MESSAGING_TOKEN"] = ""
    fire("SessionStart", env: env)
    #expect(InboxStore(paths: paths).read(sessionId: "s1") == nil)
}

@Test func sessionEndDeletesInboxAndStatus() throws {
    var (paths, env) = tmpEnv()
    env["CLAUDE_CODE_MESSAGING_SOCKET"] = "/tmp/cc-socks/abc.sock"
    env["CLAUDE_CODE_MESSAGING_TOKEN"] = "tok"
    fire("SessionStart", env: env)
    try StatusLineStore(paths: paths).write(StatusLineRecord(sessionId: "s1", updatedAt: 1))
    fire("SessionEnd", env: env)
    #expect(InboxStore(paths: paths).read(sessionId: "s1") == nil)
    #expect(StatusLineStore(paths: paths).readAll().isEmpty)
}

@Test func senderWritesAuthThenUserLine() throws {
    let dir = "/tmp/cc-socks-9\(Int.random(in: 100_000...999_999))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/t.sock"

    let server = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(server >= 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
        for (i, byte) in path.utf8.enumerated() { buffer[i] = byte }
    }
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    #expect(bound == 0)
    #expect(listen(server, 1) == 0)

    nonisolated(unsafe) var received = Data()
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        let client = accept(server, nil, nil)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            received.append(contentsOf: buffer[0..<n])
        }
        close(client)
        done.signal()
    }

    try InboxSender.send(text: "你好", to: InboxRecord(sessionId: "s1", socketPath: path, token: "secret"))
    #expect(done.wait(timeout: .now() + 5) == .success)
    close(server)

    let lines = String(decoding: received, as: UTF8.self).split(separator: "\n").map(String.init)
    #expect(lines.count == 2)
    let auth = try JSONDecoder().decode(JSONValue.self, from: Data(lines[0].utf8))
    #expect(auth["type"] == .string("auth"))
    #expect(auth["token"] == .string("secret"))
    let user = try JSONDecoder().decode(JSONValue.self, from: Data(lines[1].utf8))
    #expect(user["type"] == .string("user"))
    #expect(user["message"]?["role"] == .string("user"))
    #expect(user["message"]?["content"] == .string("你好"))
}

@Test func senderRejectsPathOutsideCcSocks() {
    for path in ["/tmp/evil.sock", "/tmp/cc-socks/../evil.sock", "/var/tmp/cc-socks/a.sock", "/tmp/cc-socks/a.txt"] {
        #expect(throws: InboxSender.Failure.notAllowedPath) {
            try InboxSender.send(text: "x", to: InboxRecord(sessionId: "s1", socketPath: path, token: "t"))
        }
    }
}

@Test func senderReportsConnectFailure() {
    #expect(throws: InboxSender.Failure.connectFailed) {
        try InboxSender.send(text: "x", to: InboxRecord(sessionId: "s1", socketPath: "/tmp/cc-socks-9000000/none.sock", token: "t"))
    }
}
