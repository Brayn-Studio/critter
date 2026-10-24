import Foundation
import Darwin
import Testing
@testable import CritterCore

private let codexID = "11111111-2222-4333-8444-555555555555"
private func line(_ type: String, _ payload: [String: Any], time: String = "2026-10-20T10:00:01.000Z") throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": time, "payload": payload], options: [.sortedKeys])
    data.append(10)
    return data
}
private func meta(source: Any = "vscode", originator: String = "Codex Desktop") throws -> Data {
    try line("session_meta", ["id": codexID, "cwd": "/work/project", "source": source,
                              "originator": originator, "timestamp": "2026-10-20T10:00:00Z"])
}
private func rollout(_ body: Data) throws -> (URL, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("rollout-test.jsonl")
    try body.write(to: url)
    return (dir, url)
}

@Test func codexSourcesKeepClientIdentity() {
    #expect(SessionSource(entrypoint: "codex-cli").label == "Codex · 终端")
    #expect(SessionSource(entrypoint: "codex-desktop").label == "Codex · Desktop")
    #expect(SessionSource(entrypoint: "codex-vscode").label == "Codex · VS Code")
    #expect(SessionSource(entrypoint: "codex_desktop") == .codexDesktop)
    #expect(SessionSource(entrypoint: "codex_terminal") == .codexTerminal)
    #expect(SessionSource(entrypoint: "codex_vscode") == .codexVSCode)
    #expect(SessionSource(entrypoint: "codex").rawValue == "codex")
    #expect(SessionSource(entrypoint: "codex").isCodex)
}

@Test func codexRolloutAcceptsGenericClientSource() throws {
    let (dir, url) = try rollout(meta(source: "codex", originator: "codex"))
    defer { try? FileManager.default.removeItem(at: dir) }
    var reader = CodexRolloutReader()
    #expect(reader.read(owner: CodexRolloutOwner(path: url.path, pid: 42, startTime: nil))?.entrypoint == "codex")
}

@Test func codexTelemetryUpdatesWithoutChangingLifecycleOrSeenState() throws {
    let (dir, url) = try rollout(meta() + line("event_msg", ["type": "task_complete"]) + line("turn_context", ["model": "gpt-6-sol", "model_context_window": 100_000]))
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = StateStore(paths: CritterPaths(critterHome: dir.appendingPathComponent("critter"), claudeHome: dir.appendingPathComponent("claude")))
    let owner = CodexRolloutOwner(path: url.path, pid: 42, startTime: 10)
    var sync = CodexSessionSync()
    sync.refresh(owners: [owner], store: store)
    let id = "codex-" + codexID
    #expect(store.read(sessionId: id)?.telemetry?.model == "gpt-6-sol")
    #expect(store.read(sessionId: id)?.telemetry?.contextWindow == 100_000)
    try store.update(sessionId: id) { previous in
        var seen = previous!
        seen.state = .idle; seen.lastEvent = "Seen"; seen.eventTime += 1
        return .write(seen)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line("turn_context", ["model": "gpt-6-astra"]))
    sync.refresh(owners: [owner], store: store)
    let seen = store.read(sessionId: id)
    #expect(seen?.state == .idle)
    #expect(seen?.lastEvent == "Seen")
    #expect(seen?.telemetry?.model == "gpt-6-astra")
    #expect(seen?.telemetry?.contextWindow == 100_000)
}

@Test func codexSyncMigratesMatchingLegacySeenWithoutDeletingClaude() throws {
    let (dir, url) = try rollout(meta() + line("event_msg", ["type": "task_complete"]))
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = StateStore(paths: CritterPaths(critterHome: dir.appendingPathComponent("critter"), claudeHome: dir.appendingPathComponent("claude")))
    var reader = CodexRolloutReader()
    let owner = CodexRolloutOwner(path: url.path, pid: 42, startTime: 10)
    let initial = reader.read(owner: owner)
    var legacy = try #require(initial)
    legacy.sessionId = codexID; legacy.entrypoint = nil; legacy.claudePid = nil
    legacy.state = .idle; legacy.lastEvent = "Seen"; legacy.eventTime += 1
    try store.update(sessionId: codexID) { _ in .write(legacy) }
    var sync = CodexSessionSync()
    sync.refresh(owners: [owner], store: store)
    #expect(store.read(sessionId: codexID) == nil)
    let imported = try #require(store.read(sessionId: "codex-" + codexID))
    #expect(imported.sessionId == "codex-" + codexID)
    #expect(imported.state == .idle)
    #expect(imported.lastEvent == "Seen")
    #expect(imported.claudePid == 42)
    #expect(imported.entrypoint == "codex-desktop")

    legacy.transcriptPath = "/Users/u/.claude/projects/x/\(codexID).jsonl"
    legacy.entrypoint = "cli"
    try store.update(sessionId: codexID) { _ in .write(legacy) }
    sync.refresh(owners: [owner], store: store)
    #expect(store.read(sessionId: codexID) == legacy)
}

@Test func codexSyncKeepsLegacyRecordWhenCanonicalWriteFails() throws {
    let (dir, url) = try rollout(meta())
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = CritterPaths(critterHome: dir.appendingPathComponent("critter"), claudeHome: dir.appendingPathComponent("claude"))
    let store = StateStore(paths: paths)
    let owner = CodexRolloutOwner(path: url.path, pid: 42, startTime: 10)
    var reader = CodexRolloutReader()
    let initial = reader.read(owner: owner)
    var legacy = try #require(initial)
    legacy.sessionId = codexID
    try store.update(sessionId: codexID) { _ in .write(legacy) }
    let canonicalFile = try #require(paths.stateFile(sessionId: "codex-" + codexID))
    try FileManager.default.createDirectory(at: canonicalFile, withIntermediateDirectories: true)
    var sync = CodexSessionSync()
    sync.refresh(owners: [owner], store: store)
    #expect(store.read(sessionId: codexID) == legacy)
}

@Test func codexDiscoveryUsesCurrentDesktopHostInsteadOfCreationSource() async throws {
    let (dir, url) = try rollout(meta(source: "cli", originator: "codex_cli_rs"))
    defer { try? FileManager.default.removeItem(at: dir) }
    let executable = dir.appendingPathComponent("Codex.app/Contents/Resources/codex")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/bash")
    child.arguments = ["-c", "exec 3< \"$1\"; exec \"$2\" 30", "critter-test", url.path, executable.path]
    try child.run()
    defer { if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) } }
    let deadline = Date().addingTimeInterval(2)
    while ProcessTools.executablePath(of: child.processIdentifier)?.hasSuffix("/Codex.app/Contents/Resources/codex") != true && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(ProcessTools.executablePath(of: child.processIdentifier)?.hasSuffix("/Codex.app/Contents/Resources/codex") == true)
    let owner = try #require(CodexDiscovery.openRollouts(in: dir).first)
    var reader = CodexRolloutReader()
    #expect(reader.read(owner: owner)?.entrypoint == "codex-desktop")
}

@Test func codexRolloutTracksLifecycleAndTools() throws {
    let (dir, url) = try rollout(meta() + line("event_msg", ["type": "task_started"]))
    defer { try? FileManager.default.removeItem(at: dir) }
    var reader = CodexRolloutReader()
    let owner = CodexRolloutOwner(path: url.path, pid: 42, startTime: 10)
    var latest = reader.read(owner: owner)
    var record = try #require(latest)
    #expect(record.sessionId == "codex-11111111-2222-4333-8444-555555555555")
    #expect(record.entrypoint == "codex-desktop")
    #expect(record.state == .running)
    #expect(record.activity == "think")
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line("response_item", ["type": "function_call", "name": "exec_command", "arguments": "{\"cmd\":\"swift test\"}"]))
    latest = reader.read(owner: owner)
    record = try #require(latest)
    #expect(record.activity == "bash")
    #expect(record.detail?.contains("swift test") == true)
    try handle.write(contentsOf: line("event_msg", ["type": "task_complete", "last_agent_message": "完成了。测试通过。"], time: "2026-10-20T10:00:02.000Z"))
    latest = reader.read(owner: owner)
    record = try #require(latest)
    #expect(record.state == .done)
    #expect(record.detail == "完成了。")
    #expect(record.activity == nil)
    try handle.write(contentsOf: line("event_msg", ["type": "token_count", "info": [:]]))
    #expect(reader.read(owner: owner)?.state == .done)
}

@Test func codexWaitInterruptErrorAndNextTurn() throws {
    let (dir, url) = try rollout(meta(source: "cli", originator: "codex_cli_rs"))
    defer { try? FileManager.default.removeItem(at: dir) }
    var reader = CodexRolloutReader()
    let owner = CodexRolloutOwner(path: url.path, pid: 42, startTime: 10)
    #expect(reader.read(owner: owner)?.entrypoint == "codex-cli")
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    for (event, state) in [("exec_approval_request", PetState.waiting), ("turn_aborted", .idle),
                           ("turn_started", .running), ("error", .error), ("task_started", .running),
                           ("request_user_input", .waiting), ("turn_complete", .done)] {
        try handle.write(contentsOf: line("event_msg", ["type": event, "message": "example"]))
        #expect(reader.read(owner: owner)?.state == state)
    }
}

@Test func codexIgnoresBackgroundAndInvalidMetadata() throws {
    for source: Any in ["exec", "mcp", ["subagent": ["thread_spawn": ["parent_thread_id": codexID]]], ["internal": "guardian"]] {
        let (dir, url) = try rollout(meta(source: source))
        defer { try? FileManager.default.removeItem(at: dir) }
        var reader = CodexRolloutReader()
        #expect(reader.read(owner: CodexRolloutOwner(path: url.path, pid: 42, startTime: nil)) == nil)
    }
    let (dir, url) = try rollout(line("session_meta", ["id": "../../escape", "cwd": "/x", "source": "cli"]))
    defer { try? FileManager.default.removeItem(at: dir) }
    var reader = CodexRolloutReader()
    #expect(reader.read(owner: CodexRolloutOwner(path: url.path, pid: 42, startTime: nil)) == nil)
}

@Test func codexPartialLinesAndTruncationAreSafe() throws {
    let (dir, url) = try rollout(meta() + line("event_msg", ["type": "task_started"]))
    defer { try? FileManager.default.removeItem(at: dir) }
    var reader = CodexRolloutReader()
    let owner = CodexRolloutOwner(path: url.path, pid: 42, startTime: nil)
    #expect(reader.read(owner: owner)?.state == .running)
    let completion = try line("event_msg", ["type": "task_complete", "last_agent_message": "你好🌱"])
    let cut = completion.count - 5
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: completion.prefix(cut))
    #expect(reader.read(owner: owner)?.state == .running)
    try handle.write(contentsOf: completion.suffix(from: cut))
    #expect(reader.read(owner: owner)?.state == .done)
    try handle.close()
    try (meta() + line("event_msg", ["type": "turn_aborted"])).write(to: url)
    #expect(reader.read(owner: owner)?.state == .idle)
}

@Test func codexSyncPreservesSeenAndRemovesOnlyClosedCodex() throws {
    let (dir, url) = try rollout(meta() + line("event_msg", ["type": "task_complete"]))
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = CritterPaths(critterHome: dir.appendingPathComponent("critter"), claudeHome: dir.appendingPathComponent("claude"))
    let store = StateStore(paths: paths)
    var sync = CodexSessionSync()
    let owner = CodexRolloutOwner(path: url.path, pid: 42, startTime: 10)
    sync.refresh(owners: [owner], store: store)
    let id = "codex-" + codexID
    try store.update(sessionId: id) { previous in
        var seen = previous!
        seen.state = .idle; seen.lastEvent = "Seen"; seen.eventTime += 1
        return .write(seen)
    }
    sync.refresh(owners: [owner], store: store)
    #expect(store.read(sessionId: id)?.state == .idle)
    sync.refresh(owners: [CodexRolloutOwner(path: url.path, pid: 43, startTime: 20)], store: store)
    #expect(store.read(sessionId: id)?.state == .idle)
    #expect(store.read(sessionId: id)?.claudePid == 43)
    #expect(SessionCatalog.build(records: store.readAll(), registry: [], dismissed: [id: Int64.max]).isEmpty)
    var claude = try #require(store.read(sessionId: id))
    claude.sessionId = "claude-test"; claude.entrypoint = "cli"
    try store.update(sessionId: claude.sessionId) { _ in .write(claude) }
    sync.refresh(owners: [], store: store)
    #expect(store.read(sessionId: id) == nil)
    #expect(store.read(sessionId: "claude-test") != nil)
}

@Test func processOpenFileDiscoveryFindsARealOpenRollout() throws {
    let (dir, url) = try rollout(Data())
    defer { try? FileManager.default.removeItem(at: dir) }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let opened = ProcessTools.openFilePaths(of: getpid())
    #expect(opened.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath() == url.resolvingSymlinksInPath() })
}

@Test(arguments: ["codex", "codex-aarch64-apple-darwin", "codex-x86_64-apple-darwin"])
func codexDiscoveryRequiresALiveProcessHoldingTheRollout(binaryName: String) async throws {
    let (dir, url) = try rollout(meta())
    defer { try? FileManager.default.removeItem(at: dir) }
    let historical = dir.appendingPathComponent("rollout-historical.jsonl")
    try meta().write(to: historical)
    let executable = dir.appendingPathComponent(binaryName)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/bash")
    child.arguments = ["-c", "exec 3< \"$1\"; exec \"$2\" 30", "critter-test", url.path, executable.path]
    try child.run()
    defer { if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) } }
    let deadline = Date().addingTimeInterval(2)
    while ProcessTools.executablePath(of: child.processIdentifier)?.hasSuffix("/" + binaryName) != true && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let owners = CodexDiscovery.openRollouts(in: dir)
    #expect(owners.count == 1)
    #expect(owners.first?.pid == child.processIdentifier)
    #expect(owners.first?.path.hasSuffix("/rollout-test.jsonl") == true)
    _ = Darwin.kill(child.processIdentifier, SIGKILL)
    let exitDeadline = Date().addingTimeInterval(2)
    while ProcessTools.isAlive(child.processIdentifier) && Date() < exitDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!ProcessTools.isAlive(child.processIdentifier))
    #expect(CodexDiscovery.openRollouts(in: dir).isEmpty)
}

@Test func codexFilesystemWatcherFindsNestedRolloutChanges() throws {
    let (dir, _) = try rollout(Data())
    defer { try? FileManager.default.removeItem(at: dir) }
    let signal = DispatchSemaphore(value: 0)
    let watcher = CodexDirectoryWatcher(url: dir, queue: DispatchQueue(label: "test.codex.files")) { signal.signal() }
    let nested = dir.appendingPathComponent("2026/10/20")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("{}\n".utf8).write(to: nested.appendingPathComponent("rollout-new.jsonl"))
    #expect(signal.wait(timeout: .now() + 5) == .success)
    withExtendedLifetime(watcher) {}
}

@Test func codexJumpUsesThreadForDesktopAndTTYForTerminal() {
    #expect(JumpPlanner.plan(guiAncestor: nil, source: .codexDesktop, cwd: "/x", tty: nil, ideLocks: [], sessionId: "codex-" + codexID)
            == .codexThread(id: codexID))
    #expect(JumpPlanner.plan(guiAncestor: AppHit(pid: 1, bundleId: JumpPlanner.terminal), source: .codexTerminal,
                             cwd: "/x", tty: "/dev/ttys001", ideLocks: []) == .terminalTab(tty: "/dev/ttys001"))
    #expect(JumpPlanner.plan(guiAncestor: nil, source: .codexVSCode, cwd: "/x", tty: nil, ideLocks: [])
            == .openFolder(bundleId: JumpPlanner.vscode, folder: "/x"))
}

@Test func codexInitialTailKeepsAnEventExactlyOnItsBoundary() throws {
    let completion = try line("event_msg", ["type": "task_complete"])
    let paddingBase = try line("future_event", ["padding": ""])
    let padding = try line("future_event", ["padding": String(repeating: "x", count: 256 * 1024 - completion.count - paddingBase.count)])
    let (dir, url) = try rollout(meta() + line("event_msg", ["type": "task_started"]) + completion + padding)
    defer { try? FileManager.default.removeItem(at: dir) }
    var reader = CodexRolloutReader()
    #expect(reader.read(owner: CodexRolloutOwner(path: url.path, pid: 42, startTime: nil))?.state == .done)
}

@Test func codexFirstReadRestoresALargeCompletionEvent() throws {
    let completion = try line("event_msg", ["type": "task_complete", "last_agent_message": "完成。" + String(repeating: "x", count: 300 * 1024)])
    let (dir, url) = try rollout(meta() + line("event_msg", ["type": "task_started"]) + completion)
    defer { try? FileManager.default.removeItem(at: dir) }
    var reader = CodexRolloutReader()
    let record = reader.read(owner: CodexRolloutOwner(path: url.path, pid: 42, startTime: nil))
    #expect(record?.state == .done)
    #expect(record?.detail == "完成。")
}

@Test func codexRuntimeRecognizesChatGPTAndPrefersTheHostingTerminal() {
    #expect(CodexDiscovery.runtimeEntrypoint(executablePaths:["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"]) == "codex-desktop")
    #expect(CodexDiscovery.runtimeEntrypoint(executablePaths:["/Applications/Codex.app/Contents/Resources/codex", "/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"]) == "codex-cli")
}

@Test func codexProgressStaysVisibleThroughCommandsAndThinking() throws {
    let progress = "最终验证通过：Swift 和 Android 测试均通过。我现在更新正在运行的桌面版，再检查实际会话的来源标签。"
    let message = try line("response_item", ["type":"message","role":"assistant","phase":"commentary","content":[["type":"output_text","text":progress]]])
    let (dir,url) = try rollout(meta() + line("event_msg",["type":"task_started"]) + message)
    defer { try? FileManager.default.removeItem(at:dir) }
    var reader = CodexRolloutReader()
    let owner = CodexRolloutOwner(path:url.path,pid:42,startTime:nil)
    #expect(reader.read(owner:owner)?.detail == progress)
    let handle = try FileHandle(forWritingTo:url); defer { try? handle.close() }; try handle.seekToEnd()
    try handle.write(contentsOf:line("response_item",["type":"custom_tool_call","name":"exec","call_id":"command-1","input":"await tools.exec_command({cmd:'rg request_user_input Sources'})"]))
    var record = reader.read(owner:owner)
    #expect(record?.state == .running)
    #expect(record?.activity == "bash")
    #expect(record?.detail == progress)
    try handle.write(contentsOf:line("response_item",["type":"reasoning","summary":[]]))
    record = reader.read(owner:owner)
    #expect(record?.activity == "bash")
    #expect(record?.detail == progress)
    try handle.write(contentsOf:line("response_item",["type":"custom_tool_call_output","call_id":"command-1","output":"done"]))
    record = reader.read(owner:owner)
    #expect(record?.activity == "think")
    #expect(record?.detail == progress)
    try handle.write(contentsOf:line("event_msg",["type":"task_started"]))
    #expect(reader.read(owner:owner)?.detail == BubbleText.thinking)
}

@Test func codexOnlyRealInputToolsEnterWaitingAndPublicProgressIsUsed() throws {
    let (dir,url) = try rollout(meta() + line("event_msg",["type":"task_started"]))
    defer { try? FileManager.default.removeItem(at:dir) }
    var reader = CodexRolloutReader(); let owner = CodexRolloutOwner(path:url.path,pid:42,startTime:nil)
    _ = reader.read(owner:owner)
    let handle = try FileHandle(forWritingTo:url); defer { try? handle.close() }; try handle.seekToEnd()
    try handle.write(contentsOf:line("response_item",["type":"function_call","name":"request_user_input_metrics","call_id":"metrics","arguments":"{}"] ))
    #expect(reader.read(owner:owner)?.state == .running)
    try handle.write(contentsOf:line("event_msg",["type":"agent_message","phase":"commentary","message":"正在构建手机安装包。"] ))
    #expect(reader.read(owner:owner)?.detail == "正在构建手机安装包。")
    try handle.write(contentsOf:line("response_item",["type":"function_call","name":"functions.request_user_input","call_id":"question-1","arguments":"{}"] ))
    #expect(reader.read(owner:owner)?.state == .waiting)
    try handle.write(contentsOf:line("response_item",["type":"function_call_output","call_id":"question-1","output":"answer"] ))
    #expect(reader.read(owner:owner)?.detail == "正在构建手机安装包。")
}

@Test func codexBackgroundCommandKeepsRunningAnimationUntilItsSessionExits() throws {
    let (dir,url) = try rollout(meta() + line("event_msg",["type":"task_started"]))
    defer { try? FileManager.default.removeItem(at:dir) }
    var reader = CodexRolloutReader(); let owner = CodexRolloutOwner(path:url.path,pid:42,startTime:nil)
    _ = reader.read(owner:owner)
    let handle = try FileHandle(forWritingTo:url); defer { try? handle.close() }; try handle.seekToEnd()
    try handle.write(contentsOf:line("response_item",["type":"custom_tool_call","name":"exec","call_id":"build","input":"await tools.exec_command({cmd:'swift build',yield_time_ms:1000})"]))
    try handle.write(contentsOf:line("response_item",["type":"custom_tool_call_output","call_id":"build","output":[["type":"input_text","text":"{\"session_id\":77,\"output\":\"building\"}"]]]))
    #expect(reader.read(owner:owner)?.activity == "bash")
    try handle.write(contentsOf:line("response_item",["type":"reasoning","summary":[]]))
    #expect(reader.read(owner:owner)?.activity == "bash")
    try handle.write(contentsOf:line("response_item",["type":"custom_tool_call","name":"exec","call_id":"poll","input":"await tools.write_stdin({session_id:77,chars:''})"]))
    try handle.write(contentsOf:line("response_item",["type":"custom_tool_call_output","call_id":"poll","output":[["type":"input_text","text":"{\"exit_code\":0,\"output\":\"done\"}"]]]))
    #expect(reader.read(owner:owner)?.activity == "think")
}

@Test func codexLateProgressCannotReviveAnAbortedTurn() throws {
    let late = try line("response_item",["type":"message","role":"assistant","phase":"commentary","content":[["type":"output_text","text":"旧进度"]]],time:"2026-10-20T10:00:02.000Z")
    let (dir,url) = try rollout(meta() + line("event_msg",["type":"task_started"]) + line("event_msg",["type":"turn_aborted"],time:"2026-10-20T10:00:03.000Z") + late)
    defer { try? FileManager.default.removeItem(at:dir) }
    var reader = CodexRolloutReader(); let owner = CodexRolloutOwner(path:url.path,pid:42,startTime:nil)
    #expect(reader.read(owner:owner)?.state == .idle)
    let handle = try FileHandle(forWritingTo:url); defer { try? handle.close() }; try handle.seekToEnd()
    try handle.write(contentsOf:line("event_msg",["type":"agent_message","phase":"commentary","message":"延迟的进度"],time:"2026-10-20T10:00:04.000Z"))
    #expect(reader.read(owner:owner)?.state == .idle)
    try handle.write(contentsOf:line("event_msg",["type":"user_message"],time:"2026-10-20T10:00:05.000Z"))
    try handle.write(contentsOf:line("event_msg",["type":"agent_message","phase":"commentary","message":"新一轮进度"],time:"2026-10-20T10:00:06.000Z"))
    #expect(reader.read(owner:owner)?.detail == "新一轮进度")
}
@Test func codexCommandStdoutCannotManufactureABackgroundSession() throws {
    let (dir,url) = try rollout(meta() + line("event_msg",["type":"task_started"]) + line("response_item",["type":"function_call","name":"exec_command","call_id":"command","arguments":"{}"])
        + line("response_item",["type":"function_call_output","call_id":"command","output":"Process exited with code 0\nFinal output:\nProcess running with session ID 77"]))
    defer { try? FileManager.default.removeItem(at:dir) }
    var reader = CodexRolloutReader()
    #expect(reader.read(owner:CodexRolloutOwner(path:url.path,pid:42,startTime:nil))?.activity == "think")
}

// Shaped like Codex 0.163+ rollouts: the async question tool is accepted at once, its question
// arrives as an async AgentMessage, and the turn usually completes right after.
private func askAsync(_ callID: String = "call-q") throws -> Data {
    let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["questions": [["title": "选哪个方案？", "options": ["方案 A", "方案 B"]]]]), as: UTF8.self)
    return try line("response_item", ["type": "function_call", "name": "request_user_input_async", "call_id": callID, "arguments": arguments])
        + line("event_msg", ["type": "item_completed", "turn_id": "turn-1", "item": ["type": "AgentMessage", "id": callID, "phase": "final_answer",
            "delivery": "async", "content": [["type": "Text", "text": "选哪个方案？"]], "questions": [["title": "选哪个方案？", "options": ["方案 A", "方案 B"]]]]])
        + line("response_item", ["type": "function_call_output", "call_id": callID, "output": "{\"accepted\":true}"])
}
private func userItem() throws -> Data {
    try line("event_msg", ["type": "item_completed", "turn_id": "turn-1", "item": ["type": "UserMessage", "id": "user-1", "content": [["type": "text", "text": "继续"]]]])
}

@Test func codexAsyncQuestionStaysWaitingAfterTheTurnEndsUntilTheNextInput() throws {
    let (dir,url) = try rollout(meta() + line("event_msg",["type":"task_started","turn_id":"turn-1"]) + userItem())
    defer { try? FileManager.default.removeItem(at:dir) }
    var reader = CodexRolloutReader(); let owner = CodexRolloutOwner(path:url.path,pid:42,startTime:nil)
    #expect(reader.read(owner:owner)?.state == .running)
    let handle = try FileHandle(forWritingTo:url); defer { try? handle.close() }; try handle.seekToEnd()
    try handle.write(contentsOf:askAsync())
    var record = reader.read(owner:owner)
    #expect(record?.state == .waiting)
    #expect(record?.detail == "Codex 在问你问题")
    #expect(record?.activity == nil)
    try handle.write(contentsOf:line("event_msg",["type":"item_completed","turn_id":"turn-1","item":["type":"AgentMessage","id":"answer-1","phase":"final_answer","content":[["type":"Text","text":"请先回答上面的问题。"]]]]))
    try handle.write(contentsOf:line("event_msg",["type":"task_complete","turn_id":"turn-1","last_agent_message":"请先回答上面的问题。"]))
    record = reader.read(owner:owner)
    #expect(record?.state == .waiting)
    #expect(record?.detail == "Codex 在问你问题")
    #expect(record?.lastEvent == "Codex:task_complete")
    try handle.write(contentsOf:line("event_msg",["type":"token_count","info":[:]]))
    #expect(reader.read(owner:owner)?.state == .waiting)
    try handle.write(contentsOf:line("event_msg",["type":"task_started","turn_id":"turn-2"]))
    #expect(reader.read(owner:owner)?.state == .running)
    try handle.write(contentsOf:line("event_msg",["type":"task_complete","turn_id":"turn-2","last_agent_message":"好的。"]))
    #expect(reader.read(owner:owner)?.state == .done)
}

@Test func codexAsyncQuestionReadInOneBatchIsStillShown() throws {
    let (dir,url) = try rollout(meta() + line("event_msg",["type":"task_started"]) + userItem() + askAsync()
        + line("event_msg",["type":"task_complete","last_agent_message":"请先回答上面的问题。"]))
    defer { try? FileManager.default.removeItem(at:dir) }
    var reader = CodexRolloutReader()
    let record = reader.read(owner:CodexRolloutOwner(path:url.path,pid:42,startTime:nil))
    #expect(record?.state == .waiting)
    #expect(record?.detail == "Codex 在问你问题")
}

@Test func codexAsyncQuestionOutranksLaterWorkAndClearsOnASteeredAnswer() throws {
    let (dir,url) = try rollout(meta() + line("event_msg",["type":"task_started"]) + userItem() + askAsync())
    defer { try? FileManager.default.removeItem(at:dir) }
    var reader = CodexRolloutReader(); let owner = CodexRolloutOwner(path:url.path,pid:42,startTime:nil)
    #expect(reader.read(owner:owner)?.state == .waiting)
    let handle = try FileHandle(forWritingTo:url); defer { try? handle.close() }; try handle.seekToEnd()
    try handle.write(contentsOf:line("event_msg",["type":"agent_message","phase":"commentary","message":"先按默认方案准备。"]))
    try handle.write(contentsOf:line("response_item",["type":"custom_tool_call","name":"exec","call_id":"command-1","input":"await tools.exec_command({cmd:'ls'})"]))
    #expect(reader.read(owner:owner)?.state == .waiting)
    try handle.write(contentsOf:line("response_item",["type":"custom_tool_call_output","call_id":"command-1","output":"done"]))
    try handle.write(contentsOf:line("response_item",["type":"reasoning","summary":[]]))
    var record = reader.read(owner:owner)
    #expect(record?.state == .waiting)
    #expect(record?.detail == "Codex 在问你问题")
    try handle.write(contentsOf:userItem())
    record = reader.read(owner:owner)
    #expect(record?.state == .running)
    #expect(record?.detail == "先按默认方案准备。")
    try handle.write(contentsOf:line("event_msg",["type":"task_complete","last_agent_message":"完成了。"]))
    #expect(reader.read(owner:owner)?.state == .done)
}

@Test func codexAsyncMessagesWithoutQuestionsAndAbortedQuestionsDoNotWait() throws {
    let note = try line("event_msg",["type":"item_completed","item":["type":"AgentMessage","id":"note-1","phase":"commentary","delivery":"async","content":[["type":"Text","text":"仅通知"]]]])
    let (dir,url) = try rollout(meta() + line("event_msg",["type":"task_started"]) + note)
    defer { try? FileManager.default.removeItem(at:dir) }
    var reader = CodexRolloutReader(); let owner = CodexRolloutOwner(path:url.path,pid:42,startTime:nil)
    #expect(reader.read(owner:owner)?.state == .running)
    let handle = try FileHandle(forWritingTo:url); defer { try? handle.close() }; try handle.seekToEnd()
    // The question can also arrive only as its async AgentMessage.
    try handle.write(contentsOf:line("event_msg",["type":"item_completed","item":["type":"AgentMessage","id":"question-2","phase":"final_answer","delivery":"async","questions":[["title":"继续吗？","options":["是","否"]]]]]))
    #expect(reader.read(owner:owner)?.state == .waiting)
    try handle.write(contentsOf:line("event_msg",["type":"turn_aborted"]))
    #expect(reader.read(owner:owner)?.state == .idle)
    try handle.write(contentsOf:line("event_msg",["type":"task_started"]) + line("event_msg",["type":"task_complete","last_agent_message":"好了。"]))
    #expect(reader.read(owner:owner)?.state == .done)
    // A question Codex rejected never reached the user.
    try handle.write(contentsOf:line("event_msg",["type":"task_started"])
        + line("response_item",["type":"function_call","name":"request_user_input_async","call_id":"bad","arguments":"{\"questions\":[]}"]))
    #expect(reader.read(owner:owner)?.state == .waiting)
    try handle.write(contentsOf:line("response_item",["type":"function_call_output","call_id":"bad","output":"questions must not be empty"]))
    #expect(reader.read(owner:owner)?.state == .running)
}
