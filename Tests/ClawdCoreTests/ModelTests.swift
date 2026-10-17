import Foundation
import Testing
@testable import ClawdCore

@Test func priorityOrder() {
    #expect(PetState.mostUrgent([.idle, .running, .done, .error, .waiting]) == .waiting)
    #expect(PetState.mostUrgent([.idle, .done, .running]) == .done)
    #expect(PetState.mostUrgent([]) == nil)
}

@Test func sourceMapping() {
    #expect(SessionSource(entrypoint: "cli") == .terminal)
    #expect(SessionSource(entrypoint: "claude-vscode") == .vscode)
    #expect(SessionSource(entrypoint: "claude-desktop") == .desktop)
    #expect(SessionSource(entrypoint: nil) == .other)
    #expect(SessionSource.isExcluded(entrypoint: "sdk-cli"))
    #expect(!SessionSource.isExcluded(entrypoint: "claude-desktop"))
}

@Test func recordJSONKeys() throws {
    let r = SessionRecord(schema: 1, sessionId: "abc-1", cwd: "/x", transcriptPath: nil, state: .waiting,
                          detail: "d", lastEvent: "PermissionRequest", eventTime: 5, createdAt: 1,
                          claudePid: 42, claudeStartTime: 100)
    let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
    #expect(obj["state"] as? String == "waiting")
    #expect(obj["sessionId"] as? String == "abc-1")
    #expect(obj["eventTime"] as? Int == 5)
    #expect(try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(r)) == r)
}

@Test func recordsWrittenBeforeEntrypointExistedStillDecode() throws {
    let old = #"{"schema":1,"sessionId":"a","cwd":"/x","state":"idle","lastEvent":"SessionStart","eventTime":5,"createdAt":5,"claudePid":42,"claudeStartTime":100}"#
    let r = try JSONDecoder().decode(SessionRecord.self, from: Data(old.utf8))
    #expect(r.entrypoint == nil)
    #expect(r.claudePid == 42)

    var withEntrypoint = r
    withEntrypoint.entrypoint = "cli"
    let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(withEntrypoint)) as! [String: Any]
    #expect(obj["entrypoint"] as? String == "cli")
    #expect(obj["schema"] as? Int == 1)
}

@Test func pathsFromEnvironment() {
    let p = ClawdPaths.fromEnvironment(["CLAWD_HOME": "/tmp/c", "CLAUDE_CONFIG_DIR": "/tmp/k", "HOME": "/Users/u"])
    #expect(p.sessionsDir.path == "/tmp/c/sessions")
    #expect(p.claudeSessionsDir.path == "/tmp/k/sessions")
    let d = ClawdPaths.fromEnvironment(["HOME": "/Users/u"])
    #expect(d.appStatusFile.path == "/Users/u/.clawd/app.json")
    #expect(d.claudeIDEDir.path == "/Users/u/.claude/ide")
    #expect(d.stateFile(sessionId: "../etc") == nil)
    #expect(d.stateFile(sessionId: "d3331ac5-4416")?.lastPathComponent == "d3331ac5-4416.json")
}

@Test func recordWithoutActivityDecodes() throws {
    let old = #"{"schema":1,"sessionId":"a","cwd":"/x","state":"running","lastEvent":"PreToolUse","eventTime":5,"createdAt":5}"#
    let r = try JSONDecoder().decode(SessionRecord.self, from: Data(old.utf8))
    #expect(r.activity == nil)

    var withActivity = r
    withActivity.activity = "bash"
    let again = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(withActivity))
    #expect(again.activity == "bash")
}
