import Foundation
import Testing
@testable import CritterCore

nonisolated(unsafe) private let bashInput: [String: Any] = ["command": "touch reject-me.txt", "description": "Create empty file reject-me.txt"]
nonisolated(unsafe) private let questionInput: [String: Any] = try! JSONSerialization.jsonObject(with: Data(#"""
{"questions":[{"question":"Pick a number","header":"Number","options":[{"label":"One","description":"Choose option One"},{"label":"Two","description":"Choose option Two"}],"multiSelect":false}]}
"""#.utf8)) as! [String: Any]
nonisolated(unsafe) private let planInput: [String: Any] = ["plan": "# Plan\n1. touch x\n", "planFilePath": "/Users/u/.claude/plans/x.md"]

private let start: Int64 = 1_000_000
/// The hook environment of a terminal session (`ask` only waits for those).
private let cli = ["CLAUDE_CODE_ENTRYPOINT": "cli"]

/// A virtual clock: `sleep` advances it and then runs `onSleep(callCount)`, which is where a
/// test plays the app (writes an answer, ages the heartbeat, removes the request...).
private final class Clock: @unchecked Sendable {
    var now: Int64 = start
    var sleeps = 0
    var onSleep: (Int) -> Void = { _ in }

    func environment(maxWaitMs: Int64 = 590_000) -> AskEnvironment {
        AskEnvironment(
            now: { self.now },
            sleep: { interval in
                self.now += Int64(interval * 1000)
                self.sleeps += 1
                self.onSleep(self.sleeps)
            },
            ownPid: 4242,
            newRequestId: { "req-1" },
            maxWaitMs: maxWaitMs
        )
    }
}

private func tmpPaths() -> CritterPaths {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("critter-ask-tests-\(UUID().uuidString)")
    return CritterPaths(critterHome: base.appendingPathComponent(".critter"), claudeHome: base.appendingPathComponent(".claude"))
}

private func writeStatus(_ paths: CritterPaths, heartbeat: Int64 = start, bridge: Bool? = true, client: Int64? = start) {
    try! AppStatusStore(paths: paths).write(
        AppStatus(pid: 1, visible: true, heartbeat: heartbeat, version: "t", bridgeEnabled: bridge, lastClientSeen: client)
    )
}

private func request(tool: String = "Bash", input: [String: Any] = bashInput) -> Data {
    let root: [String: Any] = ["session_id": "s1", "hook_event_name": "PermissionRequest", "tool_name": tool, "tool_input": input, "cwd": "/x"]
    return try! JSONSerialization.data(withJSONObject: root)
}

private func parse(_ text: String) -> JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
private func decision(_ result: HookResult) -> JSONValue? { parse(result.stdout)?["hookSpecificOutput"]?["decision"] }

@Test func askExitsImmediatelyWhenGateClosed() {
    let cases: [(String, (CritterPaths) -> Void)] = [
        ("no app.json", { _ in }),
        ("stale heartbeat", { writeStatus($0, heartbeat: start - 11_000) }),
        ("bridge disabled", { writeStatus($0, bridge: false) }),
        ("bridge never set", { writeStatus($0, bridge: nil) }),
        ("client long gone", { writeStatus($0, client: start - 11 * 60_000) }),
        ("no client ever", { writeStatus($0, client: nil) }),
    ]
    for (name, setUp) in cases {
        let paths = tmpPaths()
        setUp(paths)
        let clock = Clock()
        let result = AskCommand.run(stdin: request(), paths: paths, environment: cli, env: clock.environment())
        #expect(result == HookResult(stdout: "", exitCode: 0), Comment(rawValue: name))
        #expect(PendingStore(paths: paths).readAll().isEmpty, Comment(rawValue: name))
        #expect(clock.sleeps == 0, Comment(rawValue: name))
    }
}

/// VS Code, Desktop and SDK sessions (spec 13.3, unverified) and a missing entrypoint: `ask`
/// returns at once even with the gate wide open, prints nothing and publishes nothing.
@Test func askExitsImmediatelyOutsideTheCli() {
    let environments: [(String, [String: String])] = [
        ("vscode", ["CLAUDE_CODE_ENTRYPOINT": "claude-vscode"]),
        ("desktop", ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop"]),
        ("sdk", ["CLAUDE_CODE_ENTRYPOINT": "sdk-cli"]),
        ("empty", ["CLAUDE_CODE_ENTRYPOINT": ""]),
        ("missing", [:]),
    ]
    for (name, environment) in environments {
        let paths = tmpPaths()
        writeStatus(paths)
        let clock = Clock()
        let result = AskCommand.run(stdin: request(), paths: paths, environment: environment, env: clock.environment())
        #expect(result == HookResult(stdout: "", exitCode: 0), Comment(rawValue: name))
        #expect(PendingStore(paths: paths).readAll().isEmpty, Comment(rawValue: name))
        #expect(clock.sleeps == 0, Comment(rawValue: name))
    }
}

@Test func askOutputsAllowWhenAnswered() throws {
    let paths = tmpPaths()
    writeStatus(paths)
    let store = PendingStore(paths: paths)
    let clock = Clock()
    clock.onSleep = { _ in try! store.writeAnswer(AnswerPayload(decision: "allow"), requestId: "req-1") }
    let result = AskCommand.run(stdin: request(), paths: paths, environment: cli, env: clock.environment())
    #expect(result.exitCode == 0)
    #expect(parse(result.stdout) == parse(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#))
    #expect(store.read(requestId: "req-1") == nil)
    #expect(store.readAnswer(requestId: "req-1") == nil)
}

@Test func askWritesPendingWithDisplayInputAndMatchKey() {
    let paths = tmpPaths()
    writeStatus(paths)
    let store = PendingStore(paths: paths)
    let clock = Clock()
    nonisolated(unsafe) var seen: PendingRequest?
    clock.onSleep = { _ in
        seen = store.read(requestId: "req-1")
        store.remove(requestId: "req-1")
    }
    _ = AskCommand.run(stdin: request(), paths: paths, environment: cli, env: clock.environment())
    #expect(seen?.kind == .permission)
    #expect(seen?.sessionId == "s1")
    #expect(seen?.toolName == "Bash")
    #expect(seen?.matchKey == MatchKey.compute(toolName: "Bash", toolInput: bashInput))
    #expect(seen?.summary == ToolSummary.permission(toolName: "Bash", input: JSONValue(any: bashInput)))
    #expect(seen?.input == JSONValue(any: bashInput))
    #expect(seen?.createdAt == start)
    #expect(seen?.expiresAt == start + 590_000)
    #expect(seen?.hookPid == 4242)
}

@Test func askQuestionOutputsUpdatedInputWithAnswers() {
    let paths = tmpPaths()
    writeStatus(paths)
    let store = PendingStore(paths: paths)
    let clock = Clock()
    nonisolated(unsafe) var kind: PendingKind?
    nonisolated(unsafe) var summary: String?
    clock.onSleep = { _ in
        kind = store.read(requestId: "req-1")?.kind
        summary = store.read(requestId: "req-1")?.summary
        try! store.writeAnswer(AnswerPayload(answers: ["Pick a number": "Two"]), requestId: "req-1")
    }
    let result = AskCommand.run(stdin: request(tool: "AskUserQuestion", input: questionInput), paths: paths, environment: cli, env: clock.environment())
    #expect(kind == .question)
    #expect(summary == BubbleText.askQuestion)
    #expect(decision(result)?["behavior"] == .string("allow"))
    #expect(decision(result)?["updatedInput"]?["answers"] == .object(["Pick a number": .string("Two")]))
    #expect(decision(result)?["updatedInput"]?["questions"] == JSONValue(any: questionInput["questions"]))
}

@Test func askPlanReviseOutputsDenyWithMessage() {
    let paths = tmpPaths()
    writeStatus(paths)
    let store = PendingStore(paths: paths)
    let clock = Clock()
    clock.onSleep = { _ in try! store.writeAnswer(AnswerPayload(decision: "revise", message: "改名为 x"), requestId: "req-1") }
    let result = AskCommand.run(stdin: request(tool: "ExitPlanMode", input: planInput), paths: paths, environment: cli, env: clock.environment())
    #expect(decision(result)?["behavior"] == .string("deny"))
    #expect(decision(result)?["message"] == .string(AskDecision.reviseMessage("改名为 x")))
}

@Test func askStopsSilentlyWhenPendingRemoved() {
    let paths = tmpPaths()
    writeStatus(paths)
    let store = PendingStore(paths: paths)
    let clock = Clock()
    clock.onSleep = { _ in store.remove(requestId: "req-1") }
    let result = AskCommand.run(stdin: request(), paths: paths, environment: cli, env: clock.environment())
    #expect(result == HookResult(stdout: "", exitCode: 0))
    #expect(clock.sleeps == 1)
}

@Test func askStopsWhenHeartbeatGoesStale() {
    let paths = tmpPaths()
    writeStatus(paths)
    let clock = Clock()
    clock.onSleep = { _ in writeStatus(paths, heartbeat: start - 60_000) }
    let result = AskCommand.run(stdin: request(), paths: paths, environment: cli, env: clock.environment())
    #expect(result == HookResult(stdout: "", exitCode: 0))
    #expect(PendingStore(paths: paths).readAll().isEmpty)
}

@Test func askStopsWhenBridgeDisabledMidWait() {
    let paths = tmpPaths()
    writeStatus(paths)
    let clock = Clock()
    clock.onSleep = { _ in writeStatus(paths, heartbeat: clock.now, bridge: false) }
    let result = AskCommand.run(stdin: request(), paths: paths, environment: cli, env: clock.environment())
    #expect(result == HookResult(stdout: "", exitCode: 0))
    #expect(PendingStore(paths: paths).readAll().isEmpty)
}

@Test func askKeepsWaitingWhenClientGoesQuietMidWait() {
    let paths = tmpPaths()
    writeStatus(paths)
    let store = PendingStore(paths: paths)
    let clock = Clock()
    clock.onSleep = { n in
        if n == 1 { writeStatus(paths, heartbeat: clock.now, client: start - 20 * 60_000) }
        if n == 3 { try! store.writeAnswer(AnswerPayload(decision: "allow"), requestId: "req-1") }
    }
    let result = AskCommand.run(stdin: request(), paths: paths, environment: cli, env: clock.environment())
    #expect(decision(result)?["behavior"] == .string("allow"))
}

@Test func askGivesUpAtDeadline() {
    let paths = tmpPaths()
    writeStatus(paths)
    let clock = Clock()
    let result = AskCommand.run(stdin: request(), paths: paths, environment: cli, env: clock.environment(maxWaitMs: 1_000))
    #expect(result == HookResult(stdout: "", exitCode: 0))
    #expect(PendingStore(paths: paths).readAll().isEmpty)
    #expect(clock.sleeps == 5)
}

@Test func askIgnoresInvalidAnswerAndKeepsWaiting() {
    let paths = tmpPaths()
    writeStatus(paths)
    let store = PendingStore(paths: paths)
    let clock = Clock()
    clock.onSleep = { n in
        if n == 1 { try! store.writeAnswer(AnswerPayload(decision: "approve"), requestId: "req-1") }
        if n == 2 {
            #expect(store.readAnswer(requestId: "req-1") == nil)
            #expect(store.read(requestId: "req-1") != nil)
            try! store.writeAnswer(AnswerPayload(decision: "allow"), requestId: "req-1")
        }
    }
    let result = AskCommand.run(stdin: request(), paths: paths, environment: cli, env: clock.environment())
    #expect(decision(result)?["behavior"] == .string("allow"))
}

@Test func askWithGarbageStdinExitsSilently() {
    let paths = tmpPaths()
    writeStatus(paths)
    let clock = Clock()
    for stdin in [Data("nope".utf8), Data(#"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","tool_input":{}}"#.utf8), Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1"}"#.utf8)] {
        #expect(AskCommand.run(stdin: stdin, paths: paths, environment: cli, env: clock.environment()) == HookResult(stdout: "", exitCode: 0))
    }
    #expect(clock.sleeps == 0)
}

@Test func gateRules() {
    let fresh = AppStatus(pid: 1, visible: true, heartbeat: 100_000, version: "t", bridgeEnabled: true, lastClientSeen: 100_000)
    #expect(AskGate.shouldStart(status: fresh, now: 105_000))
    #expect(!AskGate.shouldStart(status: nil, now: 105_000))
    #expect(AskGate.shouldKeepWaiting(status: fresh, now: 105_000))
    #expect(!AskGate.shouldKeepWaiting(status: fresh, now: 111_000))
}
