import Foundation
import Testing
@testable import CritterCore

nonisolated(unsafe) private let questionInput: [String: Any] = try! JSONSerialization.jsonObject(with: Data(#"""
{"questions":[{"question":"Pick a number","header":"Number","options":[{"label":"One","description":"Choose option One"},{"label":"Two","description":"Choose option Two"}],"multiSelect":false}]}
"""#.utf8)) as! [String: Any]

private func tmpEnv() -> (paths: CritterPaths, env: [String: String]) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("critter-resolution-tests-\(UUID().uuidString)")
    let critterHome = base.appendingPathComponent(".critter")
    let claudeHome = base.appendingPathComponent(".claude")
    let env = ["CRITTER_HOME": critterHome.path, "CLAUDE_CONFIG_DIR": claudeHome.path, "HOME": base.path]
    return (CritterPaths(critterHome: critterHome, claudeHome: claudeHome), env)
}

private func pending(
    _ id: String, session: String = "s1", tool: String = "Bash", input: [String: Any]
) -> PendingRequest {
    PendingRequest(
        requestId: id, sessionId: session, kind: PendingKind(toolName: tool), toolName: tool, summary: "x",
        input: .null, matchKey: MatchKey.compute(toolName: tool, toolInput: input),
        createdAt: 0, expiresAt: 1_000_000, hookPid: 1
    )
}

private func ids(_ store: PendingStore) -> Set<String> { Set(store.readAll().map(\.requestId)) }

private func fire(_ event: String, session: String = "s1", tool: String? = nil, input: [String: Any]? = nil, env: [String: String]) -> HookResult {
    var root: [String: Any] = ["session_id": session, "cwd": "/x", "hook_event_name": event]
    if let tool { root["tool_name"] = tool }
    if let input { root["tool_input"] = input }
    return HookCommand.run(
        arguments: ["event"], stdin: try! JSONSerialization.data(withJSONObject: root), environment: env,
        now: 1000, hookParentPid: 1, launcher: FakeLauncher()
    )
}

@Test func postToolUseResolvesMatchingRequestOnly() throws {
    let (paths, env) = tmpEnv()
    let store = PendingStore(paths: paths)
    try store.write(pending("a", input: ["command": "ls"]))
    try store.write(pending("b", tool: "Edit", input: ["command": "ls"]))
    try store.write(pending("c", input: ["command": "pwd"]))
    _ = fire("PostToolUse", tool: "Bash", input: ["command": "ls"], env: env)
    #expect(ids(store) == ["b", "c"])
}

@Test func twoPendingInOneSessionResolveIndependently() throws {
    let (paths, env) = tmpEnv()
    let store = PendingStore(paths: paths)
    try store.write(pending("a", input: ["command": "a"]))
    try store.write(pending("b", input: ["command": "b"]))
    try store.write(pending("other", session: "s2", input: ["command": "a"]))
    _ = fire("PostToolUse", tool: "Bash", input: ["command": "a"], env: env)
    #expect(ids(store) == ["b", "other"])
    _ = fire("Stop", env: env)
    #expect(ids(store) == ["other"])
}

@Test func terminalAnsweredQuestionStillResolves() throws {
    let (paths, env) = tmpEnv()
    let store = PendingStore(paths: paths)
    try store.write(pending("q", tool: "AskUserQuestion", input: questionInput))
    try store.write(pending("bash", input: ["command": "ls"]))
    var answered = questionInput
    answered["answers"] = ["Pick a number": "One"]
    answered["annotations"] = [String: Any]()
    _ = fire("PostToolUse", tool: "AskUserQuestion", input: answered, env: env)
    #expect(ids(store) == ["bash"])
}

@Test func planToolResolvesWholeSessionForThatTool() throws {
    let (paths, env) = tmpEnv()
    let store = PendingStore(paths: paths)
    try store.write(pending("p", tool: "ExitPlanMode", input: ["plan": "a"]))
    try store.write(pending("other", session: "s2", tool: "ExitPlanMode", input: ["plan": "a"]))
    _ = fire("PostToolUseFailure", tool: "ExitPlanMode", input: ["plan": "a", "extra": 1], env: env)
    #expect(ids(store) == ["other"])
}

@Test func permissionDeniedResolves() throws {
    let (paths, env) = tmpEnv()
    let store = PendingStore(paths: paths)
    try store.write(pending("a", input: ["command": "ls"]))
    _ = fire("PermissionDenied", tool: "Bash", input: ["command": "ls"], env: env)
    #expect(ids(store).isEmpty)
}

@Test func userPromptSubmitClearsSession() throws {
    let (paths, env) = tmpEnv()
    let store = PendingStore(paths: paths)
    try store.write(pending("a", input: ["command": "a"]))
    try store.write(pending("b", session: "s2", input: ["command": "a"]))
    _ = fire("UserPromptSubmit", env: env)
    #expect(ids(store) == ["b"])
}

@Test func interruptedClearsSession() throws {
    let (paths, env) = tmpEnv()
    let store = PendingStore(paths: paths)
    try store.write(pending("a", input: ["command": "a"]))
    try store.write(pending("b", session: "s2", input: ["command": "a"]))
    _ = fire("Interrupted", env: env)
    #expect(ids(store) == ["b"])
}

@Test func otherEventsLeavePendingAlone() throws {
    let (paths, env) = tmpEnv()
    let store = PendingStore(paths: paths)
    try store.write(pending("a", input: ["command": "a"]))
    _ = fire("PreToolUse", tool: "Bash", input: ["command": "a"], env: env)
    _ = fire("Notification", env: env)
    #expect(ids(store) == ["a"])
}

/// With no request waiting -- the phone feature off, or nothing asked -- an event doesn't look at
/// the tool input (so no match key is computed) and creates nothing.
@Test func emptyPendingDirectoryDoesNoWork() throws {
    let (paths, _) = tmpEnv()
    let store = PendingStore(paths: paths)
    var inputLookups = 0
    func toolInput() -> Any? {
        inputLookups += 1
        return ["command": "ls"]
    }
    for event in ["PostToolUse", "PostToolUseFailure", "PermissionDenied", "UserPromptSubmit", "Stop", "SessionEnd"] {
        PendingResolution.apply(event: event, sessionId: "s1", toolName: "Bash", toolInput: toolInput(), store: store)
    }
    #expect(inputLookups == 0)
    #expect(!FileManager.default.fileExists(atPath: paths.pendingDir.path))

    // A directory holding nothing but a temp file from an interrupted write counts as empty.
    try FileManager.default.createDirectory(at: paths.pendingDir, withIntermediateDirectories: true)
    try Data("{".utf8).write(to: paths.pendingDir.appendingPathComponent(".a.json.tmp-1-2"))
    PendingResolution.apply(event: "PostToolUse", sessionId: "s1", toolName: "Bash", toolInput: toolInput(), store: store)
    #expect(inputLookups == 0)

    // With a request waiting, the input is what finds it.
    try store.write(pending("a", input: ["command": "ls"]))
    PendingResolution.apply(event: "PostToolUse", sessionId: "s1", toolName: "Bash", toolInput: toolInput(), store: store)
    #expect(inputLookups == 1)
    #expect(ids(store).isEmpty)
}

@Test func eventStillPrintsNothing() throws {
    let (paths, env) = tmpEnv()
    try PendingStore(paths: paths).write(pending("a", input: ["command": "a"]))
    #expect(fire("PostToolUse", tool: "Bash", input: ["command": "a"], env: env) == HookResult(stdout: "", exitCode: 0))
}
