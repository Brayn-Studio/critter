# Clawd 桌面宠物 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 一个原生 macOS 桌面宠物：常驻最上层的一排像素 Clawd，实时显示本机所有 Claude Code 会话（终端 / Desktop / VS Code）的状态，点击跳回对应窗口，`/pet` 显示/隐藏。

**Architecture:** Claude Code 插件的 hooks 把每个事件交给 `clawd-hook`（Swift 命令行），它把事件换算成状态，原子写入 `~/.clawd/sessions/<session_id>.json`；`Clawd.app`（AppKit + Core Animation，菜单栏常驻）监听这个目录和 `~/.claude/sessions/`、监听 claude 进程退出，渲染宠物。所有可测试的逻辑放在 `ClawdCore` 库里，两个可执行目标都很薄。

**Tech Stack:** Swift 6.4 / SwiftPM / Swift Testing；AppKit、Core Animation、SwiftUI（只用于设置窗口）、Dispatch、Carbon（全局快捷键）；零第三方依赖。

**Spec:** `docs/superpowers/specs/2026-10-17-clawd-desktop-pet-design.md`

## Global Constraints

- 平台：macOS，`platforms: [.macOS(.v14)]`；`swift-tools-version: 6.0`，Swift 6 语言模式；测试用 Swift Testing（`import Testing`），命令 `swift test`。
- 零第三方依赖。
- 内存：活动监视器"内存"（`footprint -p <pid>` 的 `phys_footprint`）≤ 50 MB（5 个会话、展开、有动画时）；空闲 CPU ≈ 0，有动画平均 < 1%。
- 主线程只做界面；文件、进程、AppleScript 一律在后台队列。
- `clawd-hook`：永远 exit 0；除 `pet`/`toggle` 子命令外**绝不向 stdout 输出**；单次执行目标 < 30 ms。
- 路径：`~/.clawd`（环境变量 `CLAWD_HOME` 可覆盖）、`~/.claude`（`CLAUDE_CONFIG_DIR` 可覆盖）。
- 状态文件 schema 版本 `1`；写入一律原子（临时文件 + rename）+ 按会话 `flock`；旧事件不得覆盖新状态。
- Bundle ID `local.clawd.pet`；URL scheme `clawd`（`clawd://show`、`clawd://hide`、`clawd://toggle`、`clawd://debug-hang`）。
- 状态与文案：`idle` 空闲 / `running` 运行中 / `waiting` 等你确认 / `done` 做完了 / `error` 出错；优先级 waiting > error > done > running > idle。
- 颜色：Clawd 身体 `#D97757`，眼睛 `#1D1D1F`；状态色 waiting `#FF9F0A`、done `#34C759`、error `#FF3B30`、running/idle `#8E8E93`。头顶配件：idle `z z`、running `•••`、waiting `?`、done `✓`、error `!`。
- Clawd 像素网格（18×5，像素宽:高 = 1:2）逐字使用：
  ```
  ...############...
  ...##o######o##...
  .################.
  ...############...
  ....#.#....#.#....
  ```
- 所有形象素材只放在 `Skins/` 目录（品牌可替换）。
- 已在 Claude Code 2.1.301 CLI 上实测确认（2026-10-17 spike）：
  - hook 进程的父进程就是 claude 进程；
  - `Stop` 带 `last_assistant_message`；`SessionEnd` 带 `reason`；`PostToolUse` 的结果字段叫 `tool_response`；
  - 用户级/项目级命令 `/pet` 会触发 `UserPromptExpansion`（`command_name: "pet"`），hook 输出 `{"decision":"block","reason":"…"}` 即拦下且不调用模型，用户看到 `UserPromptExpansion operation blocked by hook:` + reason；
  - **插件里的命令会被加命名空间（`/clawd:pet`），裸 `/pet` 必须装成用户级命令 `~/.claude/commands/pet.md`**；
  - `UserPromptSubmit` 在 `/pet` 被拦之前就会触发（prompt 为 `/pet`）；
  - 用户按 Esc 打断会在会话记录 JSONL 里写一行 `type:"user"`、带 `interruptedMessageId`、文本 `[Request interrupted by user…]`。

## Review Focus

1. **用户按 Esc 打断**——没有 `Stop` hook，Clawd 会永远卡在"运行中"。期望：≤ 1 秒内变回空闲。（Task 6 `TranscriptTail` 测试 + Task 10 transcript 监听测试）
2. **输入 `/pet`**——`UserPromptSubmit` 先触发、随后扩展被拦、永远没有 `Stop`，会话会错误地卡在"运行中"。期望：状态不变。（Task 2 reducer 测试）
3. **并行工具调用 / 多个 hook 进程同时写同一个会话**——状态文件被写坏或被旧事件覆盖。期望：最新事件胜出、文件始终是合法 JSON。（Task 3 并发测试）
4. **外接显示器拔掉、分辨率变化**——宠物跑到屏幕外，够不着。期望：自动拉回可见区域。（Task 12 `PositionModel` 测试）
5. **超长文本**（几百字的 Bash 命令、多段回复、中英混排、emoji）——气泡撑爆、挡住屏幕。期望：折叠空白、按字符截断加"…"，气泡最多 2 行，悬停看全文。（Task 2 截断测试 + Task 11 布局测试）

---

## File Structure

```
Package.swift
Makefile
Sources/
  ClawdCore/                      # 纯逻辑 + Foundation/Dispatch/Darwin/CoreGraphics，全部可测
    PetState.swift                # 状态枚举、优先级、配色
    SessionSource.swift           # 来源（终端/VS Code/Desktop/其他）
    SessionRecord.swift           # 状态文件 schema 1
    ClawdPaths.swift              # 所有路径，含环境变量覆盖
    JSONValue.swift               # 任意 JSON 值（tool_input 用）
    HookInput.swift               # hook stdin 解码
    ToolSummary.swift             # 气泡文案、截断
    StateReducer.swift            # 事件 → 状态
    StateStore.swift              # 原子写 + flock + 乱序保护
    AppStatus.swift               # ~/.clawd/app.json（心跳、可见性）
    ProcessTools.swift            # sysctl / proc_pidpath / kill(0) / tty
    ClaudeRegistry.swift          # ~/.claude/sessions/*.json 与 ~/.claude/ide/*.lock 解析
    HookCommand.swift             # clawd-hook 全部逻辑（event / pet / toggle）
    ToggleDecision.swift          # /pet 判定（含卡死重启）
    SessionCatalog.swift          # 状态文件 + registry → [PetSession]
    FlockModel.swift              # 展开/合并判定、状态计数
    TranscriptTail.swift          # 识别 Esc 打断
    SoundTrigger.swift            # 哪些状态变化要响
    Skin.swift                    # 皮肤清单模型、校验、加载、默认皮肤
    SkinRenderer.swift            # 帧 → CGImage
    Watchers.swift                # 目录 / 进程退出 / 文件追加 监听
    StartupCleanup.swift          # 启动时清理死会话
    FlockLayout.swift             # 宠物窗口内的几何排版
    PositionModel.swift           # 锚点、夹回屏幕
    JumpPlan.swift                # 跳回窗口的决策
    LaunchAgent.swift             # 开机自启 plist 内容
    HotKeySpec.swift              # 快捷键模型与显示
  clawd-hook/main.swift           # 调 HookCommand.run，写 stdout，exit 0
  ClawdApp/
    main.swift                    # NSApplication 启动
    AppDelegate.swift             # 菜单栏、URL scheme、心跳、组装各控制器
    PetPanel.swift                # 透明置顶 NSPanel
    PetController.swift           # 显示/隐藏、订阅会话快照、驱动 FlockView、声音
    SessionMonitor.swift          # 把 Watchers 接到 StateStore/Registry，发布快照
    ClawdLayer.swift              # 单只 Clawd（精灵帧 + 动作 + 配件）
    BubbleView.swift / TagView.swift / FlockView.swift
    ClickThrough.swift            # 透明区域点击穿透
    JumpBackService.swift         # 执行 JumpPlan
    SettingsStore.swift / SettingsWindow.swift / SoundPlayer.swift / HotKey.swift
Skins/clawd/manifest.json         # 默认皮肤（与内置副本逐字一致）
Support/Info.plist                # App 的 Info.plist
Support/pet-command.md            # 装到 ~/.claude/commands/pet.md
plugin/.claude-plugin/plugin.json
plugin/hooks/hooks.json
.claude-plugin/marketplace.json
scripts/build-app.sh  scripts/install.sh  scripts/uninstall.sh
scripts/demo-sessions.sh  scripts/measure.sh
Tests/ClawdCoreTests/*.swift
Tests/ClawdHookTests/HookBinaryTests.swift
```

---

### Task 1: 包骨架与核心模型

**Files:**
- Create: `Package.swift`, `Sources/ClawdCore/{PetState,SessionSource,SessionRecord,ClawdPaths}.swift`, `Sources/clawd-hook/main.swift`（暂时只 `exit(0)`）, `Sources/ClawdApp/main.swift`（暂时只 `print`）, `Tests/ClawdCoreTests/ModelTests.swift`

**Interfaces:**
- Produces:
  - `public enum PetState: String, Codable, Sendable, CaseIterable { case idle, running, waiting, done, error }`；`var priority: Int`（waiting 4, error 3, done 2, running 1, idle 0）；`var label: String`（中文文案）；`var accessory: String`；`var colorHex: String`；`static func mostUrgent(_ states: [PetState]) -> PetState?`
  - `public enum SessionSource: String, Codable, Sendable { case terminal, vscode, desktop, other }`；`init(entrypoint: String?)`（`cli`→terminal、`claude-vscode`→vscode、`claude-desktop`→desktop、其它/nil→other）；`var label: String`（终端 / VS Code / Desktop / 其他）；`static func isExcluded(entrypoint: String?) -> Bool`（`hasPrefix("sdk")`）
  - `public struct SessionRecord: Codable, Sendable, Equatable`：`schema: Int`(=1), `sessionId: String`, `cwd: String`, `transcriptPath: String?`, `state: PetState`, `detail: String?`, `lastEvent: String`, `eventTime: Int64`(ms), `createdAt: Int64`(ms，首次写入时间，之后保持), `claudePid: Int32?`, `claudeStartTime: Int64?`(秒)
  - `public struct ClawdPaths: Sendable`：`clawdHome`, `claudeHome: URL`；计算属性 `sessionsDir`(`clawdHome/sessions`), `locksDir`(`clawdHome/locks`), `appStatusFile`(`clawdHome/app.json`), `binDir`(`clawdHome/bin`), `skinsDir`(`clawdHome/skins`), `claudeSessionsDir`(`claudeHome/sessions`), `claudeIDEDir`(`claudeHome/ide`)；`static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> ClawdPaths`；`func stateFile(sessionId: String) -> URL?`（id 不匹配 `^[A-Za-z0-9-]{1,128}$` 返回 nil）

- [ ] **Step 1: 写 `Package.swift`**：库 `ClawdCore`；可执行 `clawd-hook`（依赖 ClawdCore）；可执行 `ClawdApp`，product 名 `Clawd`（依赖 ClawdCore）；测试目标 `ClawdCoreTests`（依赖 ClawdCore）、`ClawdHookTests`（依赖 `clawd-hook` 与 ClawdCore）。
- [ ] **Step 2: 写失败测试** `Tests/ClawdCoreTests/ModelTests.swift`：

```swift
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
```

- [ ] **Step 3:** `swift test --filter ModelTests` → 编译失败（类型不存在）。
- [ ] **Step 4:** 实现上面 Interfaces 中的四个文件，配色/文案取 Global Constraints。
- [ ] **Step 5:** `swift test --filter ModelTests` → 全部通过；`swift build` 无警告地构建三个目标。
- [ ] **Step 6:** Commit `feat(core): package skeleton and core models`

---

### Task 2: hook 输入解码、气泡文案、状态归约

**Files:**
- Create: `Sources/ClawdCore/{JSONValue,HookInput,ToolSummary,StateReducer}.swift`, `Tests/ClawdCoreTests/ReducerTests.swift`, `Tests/ClawdCoreTests/ToolSummaryTests.swift`

**Interfaces:**
- Consumes: `SessionRecord`, `PetState`（Task 1）
- Produces:
  - `public enum JSONValue: Decodable, Sendable, Equatable`（string/number/bool/object/array/null）；`subscript(key: String) -> JSONValue?`；`var stringValue: String?`
  - `public struct HookInput: Decodable, Sendable`，snake_case 映射：`sessionId`, `cwd`, `transcriptPath?`, `hookEventName`, `source?`, `reason?`, `prompt?`, `toolName?`, `toolInput: JSONValue?`, `notificationType?`, `message?`, `lastAssistantMessage?`, `errorType?`, `errorMessage?`, `commandName?`
  - `public enum ToolSummary`：`static func activity(toolName: String, input: JSONValue?) -> String`（≤ 40 字）；`static func permission(toolName: String, input: JSONValue?) -> String`（形如 `需要你确认：Bash(npm test)`）；`static func firstSentence(_ s: String, max: Int) -> String`；`static func truncate(_ s: String, max: Int) -> String`（先把所有空白折叠成单个空格并 trim，再按 `Character` 计数，超出则取前 `max-1` 个 + `…`）
  - `public enum BubbleText`：`thinking = "思考中…"`、`done = "做完了"`、`askQuestion = "Claude 在问你问题"`、`planApproval = "等你确认计划"`、`confirmPrefix = "需要你确认："`、`errorPrefix = "出错了："`
  - `public enum ReducerAction: Equatable, Sendable { case write(SessionRecord), delete, ignore }`
  - `public enum StateReducer { static func reduce(previous: SessionRecord?, input: HookInput, now: Int64, pid: Int32?, pidStartTime: Int64?) -> ReducerAction }`

映射（实现照此，测试也照此）：

| 事件 / 条件 | 结果 |
|---|---|
| `SessionStart`，`source` ∈ startup/resume/clear/fork | write idle，detail nil |
| `SessionStart`，`source == "compact"` 且已有记录 | ignore |
| `UserPromptSubmit`，prompt trim 后匹配 `^/pet(\s|$)` | ignore |
| `UserPromptSubmit` 其它 | write running，`思考中…` |
| `PreToolUse`，tool `AskUserQuestion` | write waiting，`Claude 在问你问题` |
| `PreToolUse`，tool `ExitPlanMode` | write waiting，`等你确认计划` |
| `PreToolUse` 其它 | write running，`ToolSummary.activity` |
| `PostToolUse` / `PostToolUseFailure` / `PermissionDenied` | write running，`思考中…` |
| `PermissionRequest` | write waiting，`ToolSummary.permission` |
| `Notification`，type ∈ permission_prompt / elicitation_dialog / elicitation_url_dialog / agent_needs_input | write waiting；detail = 已是 waiting 且有 detail 则保留，否则 `truncate(message, 60)` |
| `Notification` 其它类型 | ignore |
| `Stop` | write done；有 `last_assistant_message` 则 `做完了：` + `firstSentence(…, 50)`，否则 `做完了` |
| `StopFailure` | write error，`出错了：` + `truncate(errorMessage ?? errorType ?? "未知错误", 50)` |
| `SessionEnd` | delete |
| `UserPromptExpansion`、`SubagentStop`、未知事件 | ignore |

所有 write：`eventTime = now`，`createdAt = previous?.createdAt ?? now`，`claudePid`/`claudeStartTime` 取参数（参数为 nil 时沿用 previous），`transcriptPath` 取 input（nil 时沿用 previous）。`firstSentence`：在第一个 `。！？.!?\n` 处截断（含该标点），再 `truncate`。`activity` 规则：Bash → `Bash: <command 第一行>`；Edit/MultiEdit/NotebookEdit → `编辑 <file_path 文件名>`；Write → `写入 <文件名>`；Read → `读取 <文件名>`；Grep/Glob → `搜索 <pattern>`；WebFetch → `联网：<url host>`；WebSearch → `联网：<query>`；Agent/Task → `子任务：<description>`；Skill → `技能：<skill>`；`mcp__<server>__<tool>` → `MCP: <tool>`；其它 → 工具名。`permission`：`需要你确认：<Tool>(<参数摘要>)`，参数摘要取 command / 文件名 / url，整体 ≤ 40 字。

- [ ] **Step 1: 写失败测试**（`ReducerTests.swift`，用一个 `func input(_ json: String) -> HookInput` 帮助函数从 JSON 字面量解码）：

```swift
@Test func petPromptIsIgnored() {
    let prev = record(state: .idle)
    #expect(StateReducer.reduce(previous: prev, input: input(#"{"session_id":"s","cwd":"/x","hook_event_name":"UserPromptSubmit","prompt":"/pet"}"#), now: 10, pid: 1, pidStartTime: 1) == .ignore)
    #expect(StateReducer.reduce(previous: prev, input: input(#"{"session_id":"s","cwd":"/x","hook_event_name":"UserPromptSubmit","prompt":"  /pet  "}"#), now: 10, pid: 1, pidStartTime: 1) == .ignore)
    // "/petshop" 不是 /pet
    guard case .write(let r) = StateReducer.reduce(previous: prev, input: input(#"{"session_id":"s","cwd":"/x","hook_event_name":"UserPromptSubmit","prompt":"/petshop"}"#), now: 10, pid: 1, pidStartTime: 1) else { Issue.record(); return }
    #expect(r.state == .running)
}
@Test func permissionThenToolThenStop() { /* PermissionRequest(Bash npm test) → waiting & detail "需要你确认：Bash(npm test)"；PostToolUse → running "思考中…"；Stop(last_assistant_message "全部测试通过。接下来…") → done "做完了：全部测试通过。" */ }
@Test func askUserQuestionIsWaiting() { /* PreToolUse AskUserQuestion → waiting "Claude 在问你问题" */ }
@Test func stopFailureIsError() { /* error_type "rate_limit", error_message nil → "出错了：rate_limit" */ }
@Test func sessionEndDeletes() { /* → .delete */ }
@Test func compactKeepsState() { /* previous running + SessionStart compact → .ignore */ }
@Test func idlePromptNotificationIgnored() { /* Notification idle_prompt → .ignore */ }
@Test func createdAtPreservedAndPidCarriedOver() { /* previous createdAt 3, pid 9 ; reduce with pid nil → createdAt 3, claudePid 9, eventTime == now */ }
```

`ToolSummaryTests.swift`：

```swift
@Test func truncationCollapsesWhitespaceAndCountsCharacters() {
    #expect(ToolSummary.truncate("a\n\n  b\tc", max: 40) == "a b c")
    let long = String(repeating: "测", count: 100)
    #expect(ToolSummary.truncate(long, max: 40).count == 40)
    #expect(ToolSummary.truncate(long, max: 40).hasSuffix("…"))
    #expect(ToolSummary.truncate("🦀🦀🦀🦀", max: 3) == "🦀🦀…")
}
@Test func activitySummaries() {
    #expect(ToolSummary.activity(toolName: "Bash", input: .object(["command": .string("npm test\nnpm run lint")])) == "Bash: npm test")
    #expect(ToolSummary.activity(toolName: "Edit", input: .object(["file_path": .string("/a/b/App.swift")])) == "编辑 App.swift")
    #expect(ToolSummary.activity(toolName: "mcp__github__create_issue", input: nil) == "MCP: create_issue")
    #expect(ToolSummary.activity(toolName: "Bash", input: .object(["command": .string(String(repeating: "x", count: 500))])).count == 40)
}
@Test func permissionSummary() {
    #expect(ToolSummary.permission(toolName: "Bash", input: .object(["command": .string("npm test")])) == "需要你确认：Bash(npm test)")
}
```

- [ ] **Step 2:** `swift test --filter "ReducerTests|ToolSummaryTests"` → 失败。
- [ ] **Step 3:** 实现四个文件。
- [ ] **Step 4:** 测试全部通过。
- [ ] **Step 5:** Commit `feat(core): hook input decoding and state reducer`

---

### Task 3: 状态存储与 App 状态文件

**Files:**
- Create: `Sources/ClawdCore/{StateStore,AppStatus}.swift`, `Tests/ClawdCoreTests/StateStoreTests.swift`

**Interfaces:**
- Consumes: `ClawdPaths`, `SessionRecord`, `ReducerAction`
- Produces:
  - `public struct StateStore: Sendable { init(paths: ClawdPaths); func update(sessionId: String, _ body: (SessionRecord?) -> ReducerAction) throws; func read(sessionId: String) -> SessionRecord?; func readAll() -> [SessionRecord]; func delete(sessionId: String) }`
  - `update` 流程：确保目录存在 → `open(locksDir/<id>.lock)` + `flock(LOCK_EX)` → 读当前记录 → 调 `body` → 若 `.write(new)` 且 `previous != nil && new.eventTime < previous.eventTime` 则丢弃 → 原子写（同目录临时文件 `.<id>.json.tmp-<pid>-<random>` 再 `rename`）→ 解锁。`.delete` 删除状态文件与锁文件。非法 session id 抛错。
  - `readAll` 跳过无法解码的文件和隐藏临时文件，不抛错。
  - `public struct AppStatus: Codable, Sendable, Equatable { pid: Int32; visible: Bool; heartbeat: Int64; version: String }`；`public struct AppStatusStore: Sendable { init(paths:); func read() -> AppStatus?; func write(_ s: AppStatus) throws }`（原子写）

- [ ] **Step 1: 写失败测试**（每个测试用独立临时目录作 `CLAWD_HOME`）：

```swift
@Test func olderEventDoesNotOverwrite() throws {
    let s = StateStore(paths: tmpPaths())
    try s.update(sessionId: "a") { _ in .write(rec("a", .done, t: 20)) }
    try s.update(sessionId: "a") { _ in .write(rec("a", .running, t: 10)) }
    #expect(s.read(sessionId: "a")?.state == .done)
}
@Test func concurrentUpdatesKeepNewestAndValidJSON() throws {
    let s = StateStore(paths: tmpPaths())
    DispatchQueue.concurrentPerform(iterations: 200) { i in
        try? s.update(sessionId: "a") { _ in .write(rec("a", i.isMultiple(of: 2) ? .running : .waiting, t: Int64(i))) }
    }
    #expect(s.read(sessionId: "a")?.eventTime == 199)
}
@Test func corruptFilesAreSkipped() throws { /* 写入 "{not json" 到 sessions/b.json；readAll 只返回合法的 a */ }
@Test func deleteRemovesFile() throws { /* .delete 后 read == nil 且文件不存在 */ }
@Test func invalidSessionIdThrows() { /* update(sessionId: "../x") 抛错 */ }
@Test func appStatusRoundTrip() throws { /* write 后 read 相等 */ }
```

- [ ] **Step 2:** `swift test --filter StateStoreTests` → 失败。
- [ ] **Step 3:** 实现。
- [ ] **Step 4:** 测试通过（并发测试连跑 5 次：`for i in 1 2 3 4 5; do swift test --filter concurrentUpdates || break; done`）。
- [ ] **Step 5:** Commit `feat(core): atomic, ordered state store`

---

### Task 4: 读取外部世界——进程信息与 Claude 注册表

**Files:**
- Create: `Sources/ClawdCore/{ProcessTools,ClaudeRegistry}.swift`, `Tests/ClawdCoreTests/ProcessToolsTests.swift`, `Tests/ClawdCoreTests/RegistryTests.swift`

**Interfaces:**
- Produces:
  - `public enum ProcessTools`：`static func parentPid(of: Int32) -> Int32?`（sysctl `KERN_PROC_PID`，`kp_eproc.e_ppid`）；`static func startTime(of: Int32) -> Int64?`（`kp_proc.p_starttime.tv_sec`）；`static func executablePath(of: Int32) -> String?`（`proc_pidpath`）；`static func isAlive(_ pid: Int32) -> Bool`（`kill(pid, 0) == 0 || errno == EPERM`）；`static func tty(of: Int32) -> String?`（`e_tdev` → `devname`，返回 `/dev/ttysNNN`，无终端返回 nil）；`static func ancestors(of: Int32, maxDepth: Int) -> [Int32]`（不含自身，到 pid 1 为止）；`static func isClaudeExecutable(path: String) -> Bool`（最后一段为 `claude`，或路径含 `/claude/versions/`）
  - `public struct RegistryEntry: Sendable, Equatable { pid: Int32; sessionId: String; cwd: String; startedAt: Int64?; entrypoint: String?; kind: String?; name: String? }`
  - `public struct IDELock: Sendable, Equatable { pid: Int32?; workspaceFolders: [String]; ideName: String? }`
  - `public enum ClaudeRegistry { static func entries(in dir: URL) -> [RegistryEntry]; static func parseEntry(_ data: Data) -> RegistryEntry?; static func ideLocks(in dir: URL) -> [IDELock] }`——只读 `*.json` / `*.lock`，忽略 `.key` 等其它文件；字段缺失、类型不对、整个文件损坏都不抛错（缺 `pid` 或 `sessionId` 的条目丢弃）；**不解析也不保存 `authToken`**。
  - `public enum ClaudeProcessLocator { static func locate(sessionId: String, registry: [RegistryEntry], hookParentPid: Int32) -> (pid: Int32, startTime: Int64?)? }`：先在 registry 里按 sessionId 找；找不到则从 `hookParentPid` 起（含自身）向上最多 4 层，取第一个 `isClaudeExecutable` 的进程；都没有返回 nil（**绝不**回退成父 shell 的 pid）。

- [ ] **Step 1: 写失败测试**：

```swift
@Test func ownProcessFacts() {
    let me = getpid()
    #expect(ProcessTools.isAlive(me))
    #expect(ProcessTools.startTime(of: me) != nil)
    #expect(ProcessTools.parentPid(of: me) == getppid())
    #expect(!ProcessTools.ancestors(of: me, maxDepth: 10).isEmpty)
}
@Test func deadProcessIsNotAlive() throws {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["30"]
    try p.run(); let pid = p.processIdentifier
    #expect(ProcessTools.isAlive(pid))
    p.terminate(); p.waitUntilExit()
    #expect(!ProcessTools.isAlive(pid))
}
@Test func claudeExecutableDetection() {
    #expect(ProcessTools.isClaudeExecutable(path: "/Users/u/.local/share/claude/versions/2.1.301"))
    #expect(ProcessTools.isClaudeExecutable(path: "/x/anthropic.claude-code-2.1.300-darwin-arm64/resources/native-binary/claude"))
    #expect(ProcessTools.isClaudeExecutable(path: "/Users/u/Library/Application Support/Claude/claude-code/2.1.295/9d/claude.app/Contents/MacOS/claude"))
    #expect(!ProcessTools.isClaudeExecutable(path: "/bin/zsh"))
}
@Test func registryParsesRealShape() {
    let json = #"{"pid":20409,"sessionId":"d3331ac5-4416","cwd":"/Users/apple/CODESPACE/clawd","startedAt":1792166332523,"procStart":"Fri Oct 16 15:58:51 2026","version":"2.1.281","kind":"interactive","entrypoint":"cli","name":"clawd-c1","status":"busy","messagingSocketPath":"/tmp/cc-socks/20409.sock"}"#
    let e = ClaudeRegistry.parseEntry(Data(json.utf8))
    #expect(e == RegistryEntry(pid: 20409, sessionId: "d3331ac5-4416", cwd: "/Users/apple/CODESPACE/clawd", startedAt: 1792166332523, entrypoint: "cli", kind: "interactive", name: "clawd-c1"))
    #expect(ClaudeRegistry.parseEntry(Data("garbage".utf8)) == nil)
    #expect(ClaudeRegistry.parseEntry(Data(#"{"sessionId":"x"}"#.utf8)) == nil)
}
@Test func registryDirIgnoresKeyFilesAndCorruptFiles() { /* 临时目录放 1.json(合法)、2.json(损坏)、1.abc.key → entries 只有 1 条 */ }
@Test func ideLockParse() { /* {"pid":56642,"workspaceFolders":["/Users/apple/CODESPACE/RoboCup"],"ideName":"Visual Studio Code","transport":"ws","authToken":"x"} → IDELock(pid:56642, workspaceFolders:[…], ideName:"Visual Studio Code") */ }
@Test func locatorPrefersRegistry() { /* registry 有 sessionId → 返回该 pid；没有且祖先里也没有 claude → nil */ }
```

- [ ] **Step 2:** 运行 → 失败。
- [ ] **Step 3:** 实现。
- [ ] **Step 4:** 通过。
- [ ] **Step 5:** Commit `feat(core): process tools and Claude registry readers`

---

### Task 5: `clawd-hook` 命令

**Files:**
- Create: `Sources/ClawdCore/{HookCommand,ToggleDecision}.swift`, `Tests/ClawdCoreTests/HookCommandTests.swift`, `Tests/ClawdCoreTests/ToggleDecisionTests.swift`, `Tests/ClawdHookTests/HookBinaryTests.swift`
- Modify: `Sources/clawd-hook/main.swift`

**Interfaces:**
- Consumes: Tasks 1–4 全部
- Produces:
  - `public enum ToggleRequest: Sendable { case toggle, show, hide }`
  - `public enum ToggleAction: Equatable, Sendable { case launch(show: Bool), send(show: Bool), restart(show: Bool) }`
  - `public enum ToggleDecision { static let staleAfterMs: Int64 = 10_000; static func decide(request: ToggleRequest, status: AppStatus?, pidAlive: Bool, now: Int64) -> ToggleAction; static func message(for: ToggleAction) -> String }`
    - 无 status 或 pid 已死 → `.launch(show: request != .hide)`
    - 活着且 `now - heartbeat > staleAfterMs` → `.restart(show: …)`（toggle 时取 `!status.visible`）
    - 活着且心跳新鲜 → `.send(show: …)`（toggle 时取 `!status.visible`）
    - 文案：launch/send show → `Clawd 已显示`；launch/send hide → `Clawd 已隐藏`；restart show → `Clawd 无响应，已重启并显示`；restart hide → `Clawd 无响应，已重启并隐藏`
  - `public protocol AppLauncher: Sendable { func open(url: URL); func kill(pid: Int32) }`；`public struct SystemAppLauncher: AppLauncher`（`/usr/bin/open -g <url>`；kill 用 `SIGKILL` 并最多等 1 s）
  - `public struct HookResult: Equatable { stdout: String; exitCode: Int32 }`（exitCode 永远 0）
  - `public enum HookCommand { static func run(arguments: [String], stdin: Data, environment: [String: String], now: Int64, hookParentPid: Int32, launcher: AppLauncher) -> HookResult }`
    - `event`：解码 stdin → 读 registry → `ClaudeProcessLocator` → `StateStore.update { StateReducer.reduce(...) }`；stdout 为空。任何错误吞掉。
    - `pet`：执行 toggle，stdout 为 `{"decision":"block","reason":"<message>"}`（用 JSONSerialization 生成）。
    - `toggle`：执行 toggle，stdout 为 `<message>\n`（给兜底的模型路径用）。
    - 未知子命令：stdout 空。
    - 执行 toggle 动作：launch/send → `open clawd://show` 或 `clawd://hide`；restart → `kill(pid)` 再 `open`。
    - 诊断日志：当 `~/.clawd/debug` 文件存在时，`event` 每次向 `~/.clawd/hook.log` 追加一行 `<ISO8601> <session_id> <event> -> write:<state>|delete|ignore`（`pet`/`toggle` 记 `-> <ToggleAction>`）；日志超过 1 MB 时改名为 `hook.log.1` 再新建。没有该文件时不写任何日志。
  - `main.swift`：`HookCommand.run(arguments: Array(CommandLine.arguments.dropFirst()), stdin: FileHandle.standardInput.readDataToEndOfFile(), environment: ProcessInfo.processInfo.environment, now: <ms>, hookParentPid: getppid(), launcher: SystemAppLauncher())`，写 stdout，`exit(0)`。`event` 子命令读 stdin 时最多等 2 s（无输入就退出）。

- [ ] **Step 1: 写失败测试**：

```swift
// ToggleDecisionTests
@Test func decisions() {
    let fresh = AppStatus(pid: 1, visible: true, heartbeat: 100_000, version: "1")
    #expect(ToggleDecision.decide(request: .toggle, status: nil, pidAlive: false, now: 0) == .launch(show: true))
    #expect(ToggleDecision.decide(request: .toggle, status: fresh, pidAlive: true, now: 101_000) == .send(show: false))
    #expect(ToggleDecision.decide(request: .toggle, status: fresh, pidAlive: true, now: 200_000) == .restart(show: false))
    #expect(ToggleDecision.decide(request: .hide, status: nil, pidAlive: false, now: 0) == .launch(show: false))
    #expect(ToggleDecision.message(for: .send(show: true)) == "Clawd 已显示")
}
// HookCommandTests（FakeLauncher 记录调用；CLAWD_HOME/CLAUDE_CONFIG_DIR 指向临时目录）
@Test func eventWritesStateAndPrintsNothing() {
    let r = HookCommand.run(arguments: ["event"], stdin: Data(#"{"session_id":"s1","cwd":"/x","hook_event_name":"UserPromptSubmit","prompt":"hi"}"#.utf8), environment: env, now: 1000, hookParentPid: getpid(), launcher: fake)
    #expect(r == HookResult(stdout: "", exitCode: 0))
    #expect(StateStore(paths: paths).read(sessionId: "s1")?.state == .running)
}
@Test func garbageInputIsSilent() { /* stdin "nope" → stdout "", exit 0, sessionsDir 无文件 */ }
@Test func debugLogOnlyWhenFlagFilePresent() { /* 无 debug 文件 → 无 hook.log；touch clawdHome/debug 后再跑 UserPromptSubmit → hook.log 末行含 "UserPromptSubmit -> write:running" */ }
@Test func petPrintsBlockJSONAndLaunches() {
    let r = HookCommand.run(arguments: ["pet"], stdin: Data(), environment: env, now: 0, hookParentPid: 1, launcher: fake)
    let obj = try! JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as! [String: String]
    #expect(obj["decision"] == "block"); #expect(obj["reason"] == "Clawd 已显示")
    #expect(fake.opened == [URL(string: "clawd://show")!])
}
// HookBinaryTests：定位构建出的 clawd-hook（.xctest bundle 同目录），以临时 CLAWD_HOME 运行
@Test func binarySmoke() throws { /* 传入 Stop 事件 JSON → 退出码 0、stdout 为空、状态文件 state == "done" */ }
```

- [ ] **Step 2:** 运行 → 失败。
- [ ] **Step 3:** 实现 `ToggleDecision.swift`、`HookCommand.swift`、`main.swift`。
- [ ] **Step 4:** `swift test` 全部通过。
- [ ] **Step 5: 测延迟**：`swift build -c release --product clawd-hook && for i in 1 2 3; do /usr/bin/time -p sh -c 'echo "{\"session_id\":\"t\",\"cwd\":\"/x\",\"hook_event_name\":\"Stop\"}" | CLAWD_HOME=$(mktemp -d) .build/release/clawd-hook event'; done` → `real` 均 < 0.03。
- [ ] **Step 6:** Commit `feat(hook): clawd-hook event/pet/toggle`

---

### Task 6: 会话目录、合并模型、打断识别、提示音触发

**Files:**
- Create: `Sources/ClawdCore/{SessionCatalog,FlockModel,TranscriptTail,SoundTrigger}.swift`, `Tests/ClawdCoreTests/CatalogTests.swift`, `Tests/ClawdCoreTests/FlockModelTests.swift`, `Tests/ClawdCoreTests/TranscriptTailTests.swift`

**Interfaces:**
- Consumes: `SessionRecord`, `RegistryEntry`, `PetState`, `SessionSource`
- Produces:
  - `public struct PetSession: Sendable, Equatable, Identifiable { id: String; name: String; source: SessionSource; state: PetState; detail: String?; cwd: String; pid: Int32?; transcriptPath: String?; tracked: Bool; eventTime: Int64; sortKey: Int64 }`
  - `public enum SessionCatalog { static let untrackedHint = "重启该会话后可显示实时状态"; static func build(records: [SessionRecord], registry: [RegistryEntry], dismissed: [String: Int64]) -> [PetSession] }`
    - 以 sessionId 取并集；registry 里 `SessionSource.isExcluded(entrypoint:)` 的排除（只有记录、没有 registry 的照常显示）。
    - `name` = registry.name ?? cwd 最后一段；同名者改为 `"<name>（<来源>）"`。
    - `source` = `SessionSource(entrypoint: registry?.entrypoint)`；`pid` = registry.pid ?? record.claudePid。
    - 只有 registry 没有记录 → `state .idle`、`tracked false`、`detail untrackedHint`、`eventTime 0`。
    - `sortKey` = registry.startedAt ?? record.createdAt；按 sortKey 升序，相同按 id。
    - `dismissed[id] = t`：当 `eventTime <= t` 时不出现在结果里。
  - `public struct FlockOverride: Sendable, Equatable { var merged: Bool; var sessionCount: Int }`
  - `public enum FlockPresentation: Equatable { case empty; case expanded([PetSession], showCollapse: Bool); case merged(lead: PetSession, counts: [StateCount], total: Int) }`，`public struct StateCount: Equatable { state: PetState; count: Int }`
  - `public enum FlockModel { static func present(_ sessions: [PetSession], threshold: Int, override: FlockOverride?) -> FlockPresentation }`
    - 0 个 → `.empty`；1 个 → `.expanded(showCollapse: false)`
    - override 存在且 `sessionCount == sessions.count` → 按 override；否则 `count > threshold` 合并
    - 合并的 lead = 最急的状态里 sortKey 最小者；counts 按 waiting, error, done, running, idle 排，省略 0
    - 展开且 count ≥ 2 → `showCollapse: true`
  - `public enum TranscriptTail { static func isInterrupted(tail: Data) -> Bool }`：取最后一个完整的非空行；JSON 的 `type == "user"` 且（有 `interruptedMessageId` 键，或 `message.content` 中某个 text 以 `[Request interrupted by user` 开头）
  - `public enum SoundTrigger { static func enteredAlertStates(old: [String: PetState]?, new: [String: PetState]) -> [PetState] }`：`old == nil`（首次加载）返回空；否则返回本次**新进入** waiting/done/error 的状态（去重，按优先级排序）

- [ ] **Step 1: 写失败测试**（关键断言）：

```swift
@Test func untrackedRegistrySessionShownIdleWithHint() { /* 只有 registry(entrypoint "claude-vscode", name "robocup-81") → state .idle, tracked false, detail 提示, source .vscode */ }
@Test func sdkSessionsExcluded() { /* registry entrypoint "sdk-cli" + 同 id 的记录 → 结果为空 */ }
@Test func dismissedHiddenUntilNewEvent() { /* dismissed["a"]=50；记录 eventTime 50 → 不出现；eventTime 51 → 出现 */ }
@Test func duplicateNamesGetSourceSuffix() { /* 两个 name "api"（终端、VS Code）→ "api（终端）" 与 "api（VS Code）" */ }
@Test func autoMergeAboveThreshold() {
    let five = (0..<5).map { s("\($0)", state: $0 == 3 ? .waiting : .running, sortKey: Int64($0)) }
    guard case .merged(let lead, let counts, 5) = FlockModel.present(five, threshold: 4, override: nil) else { Issue.record(); return }
    #expect(lead.id == "3")
    #expect(counts == [StateCount(state: .waiting, count: 1), StateCount(state: .running, count: 4)])
    #expect(FlockModel.present(Array(five.prefix(4)), threshold: 4, override: nil) == .expanded(Array(five.prefix(4)), showCollapse: true))
}
@Test func overrideHoldsUntilCountChanges() { /* override merged=false,count 5 + 5 个 → expanded；6 个 → merged */ }
@Test func interruptDetected() {
    let line = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"interruptedMessageId":"msg_1"}"#
    #expect(TranscriptTail.isInterrupted(tail: Data(("{\"type\":\"assistant\"}\n" + line + "\n").utf8)))
    #expect(!TranscriptTail.isInterrupted(tail: Data((line + "\n{\"type\":\"assistant\"}\n").utf8)))
    #expect(!TranscriptTail.isInterrupted(tail: Data("half a li".utf8)))
}
@Test func soundTriggers() {
    #expect(SoundTrigger.enteredAlertStates(old: nil, new: ["a": .waiting]) == [])
    #expect(SoundTrigger.enteredAlertStates(old: ["a": .running], new: ["a": .waiting, "b": .done]) == [.waiting, .done])
    #expect(SoundTrigger.enteredAlertStates(old: ["a": .waiting], new: ["a": .waiting]) == [])
}
```

- [ ] **Step 2:** 运行 → 失败。
- [ ] **Step 3:** 实现。
- [ ] **Step 4:** 通过。
- [ ] **Step 5:** Commit `feat(core): session catalog, flock model, interrupt and sound triggers`

---

### Task 7: 皮肤系统（动画不写死）

**Files:**
- Create: `Sources/ClawdCore/{Skin,SkinRenderer}.swift`, `Skins/clawd/manifest.json`, `Tests/ClawdCoreTests/SkinTests.swift`

**Interfaces:**
- Produces:
  - `public struct SkinManifest: Codable, Sendable, Equatable { schema: Int; name: String; pixelAspect: [Int]; palette: [String: String]; frames: [String: [String]]; animations: [String: AnimationSpec] }`
  - `public struct AnimationSpec: Codable, Sendable, Equatable { frames: [String]; fps: Double; motion: Motion; tint: Tint?; accessory: Accessory? }`；`public enum Motion: String, Codable { case none, hop, wiggle, breathe }`；`public enum Tint: String, Codable { case dim }`；`public struct Accessory: Codable, Equatable { text: String; color: String }`
  - `public enum SkinValidator { static func problems(_ m: SkinManifest) -> [String] }`：所有帧行宽一致、所有帧行数一致；帧中每个非 `.` 字符都在 palette 里；每个动画引用的帧都存在；五个状态名（`PetState.rawValue`）都有动画；`fps > 0`
  - `public enum SkinLoader { static let builtinJSON: String; static func builtin() -> SkinManifest; static func load(name: String, searchDirs: [URL]) -> SkinManifest }`：按顺序找 `<dir>/<name>/manifest.json`，第一个能解码且 `problems` 为空的胜出，否则 `builtin()`
  - `public enum SkinRenderer { static func image(frame: [String], palette: [String: String], dim: Bool) -> CGImage? }`：每个格子 1×1 像素的 RGBA 位图（`.` 透明）；`dim` 时颜色与灰度 50% 混合并把 alpha 乘 0.85（显示时由图层按 1:2 比例放大）
- 默认皮肤内容（`Skins/clawd/manifest.json` 与 `builtinJSON` 逐字一致）：
  - palette `#`→`#D97757`、`o`→`#1D1D1F`；`pixelAspect` `[1,2]`
  - 帧 `base` = Global Constraints 里的网格；`blink` = `base` 第 2 行把 `o` 换成 `#`；`step` = `base` 末行换成 `...#.#......#.#...`
  - 动画：`idle` {frames [base,base,base,base,blink], fps 2, motion none, tint dim, accessory {z z, #8E8E93}}；`running` {[base,step], fps 4, hop, accessory {•••, #8E8E93}}；`waiting` {[base], 2, wiggle, accessory {?, #FF9F0A}}；`done` {[base,blink,base,base], 2, breathe, accessory {✓, #34C759}}；`error` {[base], 1, none, dim, accessory {!, #FF3B30}}

- [ ] **Step 1: 写失败测试**：

```swift
@Test func builtinMatchesSpecGrid() {
    #expect(SkinLoader.builtin().frames["base"] == ["...############...", "...##o######o##...", ".################.", "...############...", "....#.#....#.#...."])
    #expect(SkinValidator.problems(SkinLoader.builtin()).isEmpty)
}
@Test func bundledFileEqualsBuiltin() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Skins/clawd/manifest.json").standardized
    #expect(try JSONDecoder().decode(SkinManifest.self, from: Data(contentsOf: url)) == SkinLoader.builtin())
}
@Test func validatorCatchesProblems() { /* 少 waiting 动画、引用不存在的帧、帧宽不一、palette 缺字符 → 各自产生 problem */ }
@Test func loaderFallsBackOnInvalidSkin() { /* 临时目录放一个缺动画的 manifest → load 返回 builtin */ }
@Test func rendererProducesGridSizedImage() {
    let img = SkinRenderer.image(frame: SkinLoader.builtin().frames["base"]!, palette: SkinLoader.builtin().palette, dim: false)
    #expect(img?.width == 18 && img?.height == 5)
}
```

- [ ] **Step 2:** 运行 → 失败。
- [ ] **Step 3:** 实现并写 `Skins/clawd/manifest.json`。
- [ ] **Step 4:** 通过。
- [ ] **Step 5:** Commit `feat(core): data-driven skin manifest and renderer`

---

### Task 8: App 骨架、透明置顶面板、心跳、打包脚本

**Files:**
- Create: `Sources/ClawdApp/{AppDelegate,PetPanel,ClawdLayer}.swift`, `Support/Info.plist`, `scripts/build-app.sh`, `scripts/measure.sh`, `Makefile`
- Modify: `Sources/ClawdApp/main.swift`

**Interfaces:**
- Consumes: `AppStatusStore`, `SkinLoader`, `SkinRenderer`, `ClawdPaths`
- Produces:
  - `final class PetPanel: NSPanel`：`styleMask [.borderless, .nonactivatingPanel]`、`isOpaque false`、`backgroundColor .clear`、`hasShadow false`、`level .statusBar`、`collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`、`hidesOnDeactivate false`、`isMovable false`、`canBecomeKey false`
  - `final class ClawdLayer: CALayer`：`init(skin: SkinManifest, scale: CGFloat)`；`func apply(state: PetState, reduceMotion: Bool)`——取 `animations[state.rawValue]`，帧预渲染成 CGImage 缓存，`magnificationFilter = .nearest`，尺寸 `18*3*scale × 5*6*scale` pt；帧动画用 `CAKeyframeAnimation(keyPath: "contents")`（`calculationMode .discrete`，`repeatCount .infinity`）；motion：hop = `transform.translation.y` 0→3·scale→0 / 0.6 s，wiggle = `transform.rotation.z` ±4° / 0.5 s，breathe = `transform.scale` 1→1.04→1 / 1.6 s；`reduceMotion` 时不加任何动画、显示第一帧；配件用 `CATextLayer`（文字/颜色来自 spec 的 accessory）
  - `@MainActor final class AppDelegate: NSObject, NSApplicationDelegate`：`setActivationPolicy(.accessory)`；菜单栏 `NSStatusItem`（图标为 16pt 的 Clawd 模板图），菜单：`显示宠物`/`隐藏宠物`（随状态切换）、`设置…`（Task 14 前禁用）、分隔线、`退出 Clawd`；URL 处理（`NSAppleEventManager` `kAEGetURL`）：`clawd://show|hide|toggle`，`clawd://debug-hang` 仅当 `UserDefaults.standard.bool(forKey: "debugEnabled")` 为真时 `Thread.sleep(forTimeInterval: 3600)`；启动参数或 URL 未指定时默认显示；心跳：主线程 `Timer` 每 2 s 把 `AppStatus(pid, visible, heartbeat: nowMs, version)` 交给后台队列写入
  - `func setVisible(_ v: Bool)`（本任务里在 AppDelegate，Task 10 移到 PetController）
  - `scripts/build-app.sh`：`swift build -c release` → 组装 `dist/Clawd.app`（`Contents/MacOS/Clawd`、`Contents/Info.plist`、`Contents/Resources/Skins/`）→ `codesign --force --sign - dist/Clawd.app`
  - `Support/Info.plist`：`CFBundleIdentifier local.clawd.pet`、`CFBundleExecutable Clawd`、`CFBundleName Clawd`、`LSUIElement true`、`LSMinimumSystemVersion 14.0`、`CFBundleURLTypes`（scheme `clawd`）、`NSAppleEventsUsageDescription "Clawd 需要控制终端，才能在你点击时跳回对应的会话标签页。"`
  - `scripts/measure.sh`：打印 `footprint -p $(pgrep -x Clawd)` 中的 `phys_footprint` 与 `ps -o %cpu= -p <pid>` 连续 10 次采样的平均值
  - `Makefile`：`build`、`test`、`app`（调 build-app.sh）、`install`、`uninstall`（后两个在 Task 9 实现）

本任务的面板先显示**一只** idle Clawd，位置为主屏 `visibleFrame` 右下角内缩 24 pt。皮肤用 `SkinLoader.load(name: "clawd", searchDirs: [paths.skinsDir, Bundle.main.resourceURL!.appending(path: "Skins")])`（用户目录优先，可覆盖内置皮肤）。

- [ ] **Step 1:** 实现上述文件。
- [ ] **Step 2:** `make app && open dist/Clawd.app` → 右下角出现一只灰色打瞌睡的 Clawd，眨眼动画在播；菜单栏出现图标。
- [ ] **Step 3: 验证置顶与跨空间**：切到另一个桌面空间、让任一应用全屏 → Clawd 仍可见；点击其它应用后 Clawd 不抢焦点（⌘Tab 列表里没有 Clawd）。
- [ ] **Step 4: 验证 URL 与心跳**：`open -g clawd://hide` → 消失；`open -g clawd://show` → 出现；`cat ~/.clawd/app.json` 两次间隔 3 s，`heartbeat` 增加、`visible` 正确。
- [ ] **Step 5: 验证内存**：`scripts/measure.sh` → `phys_footprint` < 30 MB，CPU 平均 < 1%。
- [ ] **Step 6:** Commit `feat(app): menu-bar app with transparent always-on-top pet panel`

---

### Task 9: 插件、安装/卸载、`/pet`

**Files:**
- Create: `plugin/.claude-plugin/plugin.json`, `plugin/hooks/hooks.json`, `.claude-plugin/marketplace.json`, `Support/pet-command.md`, `scripts/install.sh`, `scripts/uninstall.sh`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `clawd-hook`（Task 5）、`dist/Clawd.app`（Task 8）
- Produces:
  - `plugin.json`：`{"name":"clawd","version":"0.1.0","description":"Clawd 桌面宠物：上报 Claude Code 会话状态"}`
  - `marketplace.json`：marketplace 名 `clawd-pet`，一个插件 `clawd`，`source: "./plugin"`
  - `hooks.json`：以下事件各一条、无 matcher、`{"type":"command","command":"\"$HOME/.clawd/bin/clawd-hook\" event","timeout":5}`：`SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest, PermissionDenied, Notification, Stop, StopFailure`；外加 `UserPromptExpansion`，`matcher: "^pet$"`，命令 `"$HOME/.clawd/bin/clawd-hook" pet`，`timeout: 10`。不用 async（同步保证同一会话内的顺序；`clawd-hook` 足够快）。
  - `Support/pet-command.md`：首行之后含标记 `<!-- clawd-pet -->`；frontmatter `description: 显示/隐藏 Clawd 桌面宠物`；正文是兜底说明：「用 Bash 工具运行 `"$HOME/.clawd/bin/clawd-hook" toggle`，然后只回复它输出的那一行，不要做别的。」（正常情况下 hook 会先拦下，模型看不到这段）
  - `install.sh`（幂等）：`make app` → 复制到 `~/Applications/Clawd.app` → `lsregister -f` 注册 URL scheme → `swift build -c release --product clawd-hook` 并复制到 `~/.clawd/bin/clawd-hook` → 若 `~/.claude/commands/pet.md` 存在且不含标记则**中止并提示**，否则写入 → `claude plugin marketplace add "$REPO"` 与 `claude plugin install clawd@clawd-pet`（已装则 `claude plugin update`）→ 打印"已打开的 Claude Code 会话需要重启才会加载 hooks"
  - `uninstall.sh`：`claude plugin uninstall clawd@clawd-pet`、`claude plugin marketplace remove clawd-pet`、退出并删除 `~/Applications/Clawd.app`、删除带标记的 `~/.claude/commands/pet.md`、删除 `~/.clawd`、删除 `~/Library/LaunchAgents/local.clawd.pet.plist`

- [ ] **Step 1:** 写上述文件。
- [ ] **Step 2:** `claude plugin validate plugin && claude plugin validate .` → 无错误。
- [ ] **Step 3:** `make install` → 成功；`claude plugin list` 含 `clawd@clawd-pet`；`ls ~/.clawd/bin/clawd-hook ~/.claude/commands/pet.md`。
- [ ] **Step 4: 端到端（CLI）**：`touch ~/.clawd/debug && cd $(mktemp -d) && claude -p "回复 ok" --model haiku < /dev/null; grep -E "SessionStart|UserPromptSubmit|Stop|SessionEnd" ~/.clawd/hook.log | tail -4` → 依次为 `-> write:idle`、`-> write:running`、`-> write:done`、`-> delete`；`ls ~/.clawd/sessions/` 里没有残留该会话；`rm ~/.clawd/debug`。
- [ ] **Step 5: `/pet`**：`claude -p "/pet" < /dev/null` → 输出含 `UserPromptExpansion operation blocked by hook:` 和 `Clawd 已显示`/`Clawd 已隐藏`，宠物随之切换；再执行一次切回。
- [ ] **Step 6:** `make uninstall` → 以上文件全部消失、`claude plugin list` 不再含 clawd；再 `make install` 恢复。
- [ ] **Step 7:** Commit `feat: Claude Code plugin, installer and /pet`

---

### Task 10: 会话监听与快照（App 的数据层）

**Files:**
- Create: `Sources/ClawdCore/{Watchers,StartupCleanup}.swift`, `Sources/ClawdApp/{SessionMonitor,PetController}.swift`, `Tests/ClawdCoreTests/WatchersTests.swift`, `Tests/ClawdCoreTests/StartupCleanupTests.swift`
- Modify: `Sources/ClawdApp/AppDelegate.swift`（可见性移交 PetController）

**Interfaces:**
- Consumes: `StateStore`, `ClaudeRegistry`, `SessionCatalog`, `TranscriptTail`, `ProcessTools`
- Produces:
  - `public final class DirectoryWatcher: @unchecked Sendable { init(url: URL, queue: DispatchQueue, debounce: TimeInterval = 0.1, onChange: @escaping @Sendable () -> Void); func start(); func stop() }`（`DispatchSource.makeFileSystemObjectSource`，`.write`；目录不存在时先创建）
  - `public final class ProcessExitWatcher: @unchecked Sendable { init(queue:, onExit: @escaping @Sendable (Int32) -> Void); func watch(pid: Int32); func unwatch(pid: Int32) }`（`DispatchSource.makeProcessSource(.exit)`；注册时进程已死则立刻回调）
  - `public final class FileAppendWatcher: @unchecked Sendable { init(url:, queue:, debounce: 0.3, onAppend: @escaping @Sendable (Data) -> Void) }`（`.write | .extend`；回调给文件末尾最多 16 KB）
  - `public enum StartupCleanup { static func deadSessionIds(records: [SessionRecord], isAlive: (Int32) -> Bool, startTime: (Int32) -> Int64?, now: Int64) -> [String] }`：有 pid 且（进程不在 或 记录有 `claudeStartTime` 而当前启动时间与之相差 > 2 s）→ 死；记录没有 `claudeStartTime` 时只看进程是否存在；无 pid 且 `now - eventTime > 24h` → 死。`SessionMonitor` 在对某个 pid 调 `watch` 之前也用同一规则判断，不符直接按已退出处理（防进程号复用）。
  - `@MainActor final class SessionMonitor`：后台串行队列上监听 `sessionsDir` 与 `claudeSessionsDir`；每次变化重建 `[PetSession]`（`SessionCatalog.build`）并在主线程回调 `onSnapshot([PetSession])`；为每个有 pid 的会话 `watch(pid)`，退出时 `StateStore.delete` + 重建；对 `running`/`waiting` 且有 `transcriptPath` 的会话挂 `FileAppendWatcher`，`TranscriptTail.isInterrupted` 为真时 `StateStore.update` 写 `idle`（`lastEvent "Interrupted"`，`eventTime now`）；启动时执行 `StartupCleanup` 并删除死会话；`func markSeen(_ id: String)`（done → idle）；`func dismiss(_ id: String)`（记入 UserDefaults `dismissed` 字典，值为该会话当前 eventTime；同时清理已不存在的会话的条目）
  - `@MainActor final class PetController`：持有 PetPanel；`var visible: Bool`；`func setVisible(_:)`（显示 `orderFrontRegardless`，隐藏 `orderOut`）；接收快照（本任务里先用最简单的方式——每个会话一只 ClawdLayer 横排——证明数据通路；正式排版在 Task 11）

- [ ] **Step 1: 写失败测试**：

```swift
@Test func directoryWatcherFiresOnAtomicRename() async throws { /* 临时目录；start；写临时文件再 rename 进去 → 1 s 内回调 */ }
@Test func processExitWatcherFires() async throws { /* 启动 /bin/sleep 30，watch，terminate → 1 s 内收到该 pid */ }
@Test func processExitWatcherFiresImmediatelyForDeadPid() async throws { /* 已退出的 pid → 立即回调 */ }
@Test func appendWatcherDeliversTail() async throws { /* 文件追加一行 → 回调的 Data 以该行结尾 */ }
@Test func cleanupRules() {
    let alive: (Int32) -> Bool = { $0 == 10 || $0 == 11 }
    let start: (Int32) -> Int64? = { $0 == 10 ? 100 : 500 }
    let recs = [rec("a", pid: 10, start: 100), rec("b", pid: 11, start: 100), rec("c", pid: 12, start: 1),
                rec("d", pid: nil, t: 0), rec("e", pid: 11, start: nil)]
    #expect(Set(StartupCleanup.deadSessionIds(records: recs, isAlive: alive, startTime: start, now: 90_000_000)) == ["b", "c", "d"])
}
```

- [ ] **Step 2:** 运行 → 失败；**Step 3:** 实现 Core 部分 → 通过。
- [ ] **Step 4:** 实现 `SessionMonitor`、`PetController` 并接入 AppDelegate。
- [ ] **Step 5:** 写 `scripts/demo-sessions.sh N [state…]`：启动 N 个 `sleep 3600` 进程，为每个原子写入一个状态文件 `demo-<i>.json`（状态依次取参数或 waiting/done/running/idle/error 循环，`claudePid` 为该 sleep 的 pid，不写 `claudeStartTime`，`cwd` 为 `/tmp/demo-<i>`，`eventTime` 为当前毫秒）；`demo-sessions.sh set <i> <state> [detail]` 改某个会话的状态；`demo-sessions.sh clean` 杀掉这些进程并删除文件。
- [ ] **Step 6: 手动验证**：`make app && open dist/Clawd.app`；`scripts/demo-sessions.sh 3` → 3 只 Clawd；`kill` 其中一个 sleep → 那只在 1 s 内消失；在一个真实终端会话里（插件已装、会话已重启）发一个长任务再按 Esc → 那只 1 s 内变空闲。
- [ ] **Step 7:** Commit `feat(app): session monitoring, exit detection, interrupt detection`

---

### Task 11: 宠物渲染——一排 Clawd、气泡、标签、合并堆

**Files:**
- Create: `Sources/ClawdCore/FlockLayout.swift`, `Sources/ClawdApp/{BubbleView,TagView,FlockView}.swift`, `Tests/ClawdCoreTests/FlockLayoutTests.swift`
- Modify: `Sources/ClawdApp/{PetController,ClawdLayer}.swift`

**Interfaces:**
- Consumes: `FlockPresentation`, `PetSession`, `ClawdLayer`
- Produces:
  - `public struct FlockLayout`：`public struct Metrics { scale: CGFloat; bubbleWidth: CGFloat = 132; bubbleHeight: CGFloat = 52; columnGap: CGFloat = 10; padding: CGFloat = 8; tagHeight: CGFloat = 24; accessoryHeight: CGFloat = 14; handleSize = CGSize(width: 44, height: 18) }`；`public struct Slot { id: String; clawd: CGRect; accessory: CGRect; tag: CGRect; bubble: CGRect? }`；`public struct Result { size: CGSize; slots: [Slot]; handle: CGRect?; chips: CGRect?; hitRects: [CGRect] }`；`static func layout(_ p: FlockPresentation, metrics: Metrics) -> Result`
    - Clawd 尺寸 `54·scale × 30·scale`；列宽 = 有气泡 ? `max(bubbleWidth, clawd 宽)` : `clawd 宽 + 12`；所有气泡底边对齐在配件行之上；坐标系原点左下（AppKit）
    - `.empty`：一只 idle Clawd，无气泡
    - `.merged`：一列；Clawd 区域宽 `clawd 宽 + 24·scale`（后面两只错位叠放）；配件行换成计数 chips；标签文字 `"<total> 个会话 · 点击展开"`
    - `hitRects` = 所有 clawd ∪ 气泡 ∪ 标签 ∪ handle ∪ chips 的矩形
  - `BubbleView`：圆角白底、左侧 4 pt 状态色条；第一行小字 `"<来源> · <名字>"`，第二部分 detail（11 pt，最多 2 行，尾部截断）；`toolTip` = 完整 detail
  - `TagView`：名字（10 pt）+ 来源（8 pt），未跟踪的会话名字后加 `·未接入`
  - `FlockView: NSView`：根据 `FlockLayout.Result` 摆放 ClawdLayer / BubbleView / TagView / 收起把手（文字 `⇥ 收起`）/ 计数 chips（`? 1`、`✓ 1`、`••• 2`，各用状态色）；会话 id 不变时复用已有 ClawdLayer，只在状态变化时 `apply(state:)`（避免每次快照重建动画）
  - 窗口尺寸 = `Result.size`；锚定逻辑在 Task 12，本任务固定右下角

- [ ] **Step 1: 写失败测试**：

```swift
@Test func expandedSlotsNeverOverlap() {
    let sessions = (0..<4).map { s("\($0)", state: [.waiting, .done, .running, .idle][$0]) }
    let r = FlockLayout.layout(.expanded(sessions, showCollapse: true), metrics: .init(scale: 1))
    let rects = r.slots.flatMap { [$0.clawd, $0.tag] + ($0.bubble.map { [$0] } ?? []) }
    for (i, a) in rects.enumerated() { for b in rects[(i+1)...] { #expect(!a.intersects(b)) } }
    #expect(r.slots.filter { $0.bubble != nil }.count == 3)   // idle 没有气泡
    #expect(r.handle != nil)
}
@Test func clawdScalesLinearly() {
    let one = FlockLayout.layout(.empty, metrics: .init(scale: 1)).slots[0].clawd.size
    let two = FlockLayout.layout(.empty, metrics: .init(scale: 2)).slots[0].clawd.size
    #expect(one == CGSize(width: 54, height: 30)); #expect(two == CGSize(width: 108, height: 60))
}
@Test func everythingInsideBounds() { /* 每个 hitRect 都在 CGRect(origin: .zero, size: r.size) 内（展开/合并/空 三种） */ }
@Test func mergedHasChipsAndOneBubble() { /* merged → chips != nil，slots.count == 1，lead 非 idle 时 bubble != nil */ }
```

- [ ] **Step 2:** 运行 → 失败；**Step 3:** 实现 `FlockLayout` → 通过。
- [ ] **Step 4:** 实现视图并接入 PetController。
- [ ] **Step 5: 手动验证**：`scripts/demo-sessions.sh 4`（waiting/done/running/idle 各一）→ 与浏览器原型（`.superpowers/brainstorm/*/content/flock-merge.html` 左图）结构一致，气泡互不重叠；`scripts/demo-sessions.sh 5` → 自动合并成一堆，chips 计数正确，前面那只在摇摆；写一个 400 字的 detail → 气泡只有 2 行、悬停看到全文；系统设置打开「减少动态效果」→ 动画全停。
- [ ] **Step 6:** `scripts/measure.sh`（5 个会话展开 + 有动画）→ `phys_footprint` ≤ 50 MB，CPU < 1%。
- [ ] **Step 7:** Commit `feat(app): flock rendering with bubbles, tags and merged pile`

---

### Task 12: 交互——点击穿透、拖动与位置、点击/右键、关闭

**Files:**
- Create: `Sources/ClawdCore/PositionModel.swift`, `Sources/ClawdApp/ClickThrough.swift`, `Tests/ClawdCoreTests/PositionModelTests.swift`
- Modify: `Sources/ClawdApp/{FlockView,PetController}.swift`

**Interfaces:**
- Consumes: `FlockLayout.Result.hitRects`, `SessionMonitor.markSeen/dismiss`, `JumpBackService`（Task 13；本任务里先留一个 `onJump: (PetSession) -> Void` 回调）
- Produces:
  - `public struct Anchor: Codable, Equatable { var side: Side; var x: CGFloat; var y: CGFloat }`，`enum Side: String, Codable { case left, right }`（x 是左边缘或右边缘，y 是底边，屏幕坐标）
  - `public enum PositionModel { static func anchor(for frame: CGRect, in screen: CGRect) -> Anchor`（中心在屏幕左半 → `.left`、x = minX；否则 `.right`、x = maxX；y = minY）`; static func frame(size: CGSize, anchor: Anchor, visible: CGRect) -> CGRect`（按锚点算出 frame 后夹进 `visible`，留 4 pt 边距；size 比 visible 大时贴左下）`; static func defaultAnchor(visible: CGRect) -> Anchor`（右下角内缩 24） }`
  - `final class ClickThroughController`：全局 + 本地 `mouseMoved`/`leftMouseDragged` 监听；鼠标（`NSEvent.mouseLocation`）落在任一 hitRect（换算到屏幕坐标）内 → `panel.ignoresMouseEvents = false`，否则 `true`；拖动进行中保持 false；`panel.acceptsMouseMovedEvents = true`
  - FlockView 鼠标行为：按下后位移 < 3 pt 松开 = 点击；≥ 3 pt = 拖动整个面板，松开时 `PositionModel.anchor` 存入 UserDefaults `anchor`
    - 点击单只 Clawd 或其气泡 → `onJump(session)` + `markSeen(id)`（仅当 state == done）
    - 点击合并堆 → `FlockOverride(merged: false, sessionCount: n)`；点击收起把手 → `FlockOverride(merged: true, …)`
    - 右键单只 Clawd → 菜单 `跳回会话`、`关闭`、分隔、`隐藏宠物`、`设置…`；右键合并堆 → `展开`、分隔、`隐藏宠物`、`设置…`；右键空状态 → `隐藏宠物`、`设置…`
    - `关闭` → `SessionMonitor.dismiss(id)`
  - PetController：每次布局后 `panel.setFrame(PositionModel.frame(size:anchor:visible:))`；监听 `NSApplication.didChangeScreenParametersNotification` 重新夹回；锚点所在屏幕不存在时用主屏

- [ ] **Step 1: 写失败测试**：

```swift
@Test func anchorSideFollowsCenter() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    #expect(PositionModel.anchor(for: CGRect(x: 100, y: 50, width: 200, height: 80), in: screen) == Anchor(side: .left, x: 100, y: 50))
    #expect(PositionModel.anchor(for: CGRect(x: 700, y: 50, width: 200, height: 80), in: screen) == Anchor(side: .right, x: 900, y: 50))
}
@Test func rightAnchorGrowsLeftward() {
    let f = PositionModel.frame(size: CGSize(width: 300, height: 80), anchor: Anchor(side: .right, x: 900, y: 50), visible: CGRect(x: 0, y: 0, width: 1000, height: 800))
    #expect(f.maxX == 900 && f.minY == 50)
}
@Test func offscreenAnchorIsPulledBack() {
    // 外接屏拔掉后锚点落在 x=2500
    let f = PositionModel.frame(size: CGSize(width: 300, height: 80), anchor: Anchor(side: .right, x: 2500, y: 900), visible: CGRect(x: 0, y: 0, width: 1440, height: 875))
    #expect(CGRect(x: 0, y: 0, width: 1440, height: 875).insetBy(dx: 4, dy: 4).contains(f))
}
@Test func oversizedFlockPinsBottomLeft() { /* size 宽于 visible → f.minX == visible.minX + 4 */ }
```

- [ ] **Step 2:** 运行 → 失败；**Step 3:** 实现 `PositionModel` → 通过。
- [ ] **Step 4:** 实现 ClickThrough 与 FlockView 鼠标/菜单逻辑。
- [ ] **Step 5: 手动验证**：`scripts/demo-sessions.sh 3`；鼠标在两只 Clawd 之间的空隙、气泡上方的空白处点击 → 点到的是下面的窗口；拖动整排到屏幕左上 → 松手后位置保留，`killall Clawd; open ~/Applications/Clawd.app` 后仍在原处；在「显示器」设置里改分辨率 → 宠物仍完整可见；右键 → 关闭 → 那只消失，对该会话写一个更新 eventTime 的状态文件 → 重新出现；点击合并堆展开、点收起合并。
- [ ] **Step 6:** Commit `feat(app): click-through, drag, anchored position, menus and dismiss`

---

### Task 13: 跳回对应会话窗口

**Files:**
- Create: `Sources/ClawdCore/JumpPlan.swift`, `Sources/ClawdApp/JumpBackService.swift`, `Tests/ClawdCoreTests/JumpPlanTests.swift`
- Modify: `Sources/ClawdApp/PetController.swift`（把 `onJump` 接到服务）

**Interfaces:**
- Consumes: `ProcessTools.ancestors/tty`, `ClaudeRegistry.ideLocks`, `PetSession`
- Produces:
  - `public struct AppHit: Equatable { pid: Int32; bundleId: String? }`
  - `public enum JumpPlan: Equatable { case terminalTab(tty: String), itermSession(tty: String), openFolder(bundleId: String, folder: String), activate(pid: Int32), activateBundle(String), none }`
  - `public enum JumpPlanner { static let vscodeFamily: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.google.antigravity", "com.exafunction.windsurf"]; static let claudeDesktop = "com.anthropic.claudefordesktop"; static func plan(guiAncestor: AppHit?, source: SessionSource, cwd: String, tty: String?, ideLocks: [IDELock]) -> JumpPlan; static func workspace(for cwd: String, locks: [IDELock]) -> String?`（取 `workspaceFolders` 中是 cwd 前缀且最长者）`; static func terminalScript(tty: String) -> String; static func itermScript(tty: String) -> String }`
    - 规则：祖先 bundleId 是 `com.apple.Terminal` 且有 tty → `.terminalTab`；`com.googlecode.iterm2` 且有 tty → `.itermSession`；在 vscodeFamily → `.openFolder(bundleId, workspace ?? cwd)`；其它有祖先 → `.activate(pid)`；没有祖先：source desktop → `.activateBundle(claudeDesktop)`，vscode → `.openFolder("com.microsoft.VSCode", workspace ?? cwd)`，否则 `.none`
    - `terminalScript`：遍历 `windows` 的 `tabs`，`tty of t is "<tty>"` 时 `set selected of t to true`、`set index of w to 1`、`activate`；`itermScript` 同理遍历 `sessions`，`select`。tty 字符串里的 `"` 与 `\` 必须转义。
  - `@MainActor final class JumpBackService { func jump(to: PetSession) }`：后台队列上沿 `ProcessTools.ancestors(of: pid, maxDepth: 12)` 找第一个 `NSRunningApplication(processIdentifier:)` 且 `activationPolicy == .regular` 的进程作为 guiAncestor；`tty(of: pid)`；读 ide locks；执行计划：AppleScript 用 `/usr/bin/osascript -e`（子进程、3 s 超时后 terminate）；`openFolder` 用 `NSWorkspace.shared.open([folderURL], withApplicationAt: appURL, configuration:)`（`activates = true`）；`activate` 用 `NSRunningApplication.activate()`；失败都静默（写一行 `os_log`）

- [ ] **Step 1: 写失败测试**：

```swift
@Test func terminalWithTtyTargetsTab() {
    #expect(JumpPlanner.plan(guiAncestor: AppHit(pid: 5, bundleId: "com.apple.Terminal"), source: .terminal, cwd: "/a", tty: "/dev/ttys003", ideLocks: []) == .terminalTab(tty: "/dev/ttys003"))
}
@Test func vscodeOpensMatchingWorkspace() {
    let locks = [IDELock(pid: 1, workspaceFolders: ["/Users/apple/CODESPACE/RoboCup"], ideName: "Visual Studio Code")]
    #expect(JumpPlanner.plan(guiAncestor: AppHit(pid: 9, bundleId: "com.microsoft.VSCode"), source: .vscode, cwd: "/Users/apple/CODESPACE/RoboCup/src", tty: nil, ideLocks: locks) == .openFolder(bundleId: "com.microsoft.VSCode", folder: "/Users/apple/CODESPACE/RoboCup"))
}
@Test func cliInsideVSCodeTerminalOpensVSCode() { /* source .terminal + 祖先 com.microsoft.VSCode → .openFolder */ }
@Test func desktopWithoutAncestorActivatesClaude() { /* guiAncestor nil, source .desktop → .activateBundle("com.anthropic.claudefordesktop") */ }
@Test func scriptsEscapeTty() { /* tty 含 " → 脚本中为 \" ；脚本包含 tty of t is */ }
```

- [ ] **Step 2:** 运行 → 失败；**Step 3:** 实现 `JumpPlan.swift` → 通过。
- [ ] **Step 4:** 实现 `JumpBackService` 并接入。
- [ ] **Step 5: 手动验证**：Terminal.app 开两个标签各跑一个 claude 会话，切到浏览器，点其中一只 → Terminal 前置且选中正确标签（首次出现"自动化"授权弹窗，允许）；VS Code 里的会话（RoboCup）→ 对应 VS Code 窗口前置；Desktop 会话 → Claude.app 前置。
- [ ] **Step 6:** Commit `feat(app): jump back to the session's window`

---

### Task 14: 设置页、提示音占位、全局快捷键、开机自启

**Files:**
- Create: `Sources/ClawdCore/{LaunchAgent,HotKeySpec}.swift`, `Sources/ClawdApp/{SettingsStore,SettingsWindow,SoundPlayer,HotKey}.swift`, `Tests/ClawdCoreTests/LaunchAgentTests.swift`, `Tests/ClawdCoreTests/HotKeyFormatTests.swift`
- Modify: `Sources/ClawdApp/{AppDelegate,PetController}.swift`

**Interfaces:**
- Consumes: `SoundTrigger`, `PetController`, `PositionModel.defaultAnchor`
- Produces:
  - `@MainActor @Observable final class SettingsStore`（UserDefaults 持久化）：`petScale: Double`（默认 1.0，0.5…2.0，步长 0.25）、`soundEnabled: Bool`（true）、`soundOnWaiting`/`soundOnDone`/`soundOnError: Bool`（true）、`mergeThreshold: Int`（4，2…10）、`hotKey: HotKeySpec`（默认 ⌃⌥C）、`launchAtLogin: Bool`（false）
  - `Sources/ClawdCore/HotKeySpec.swift`：`public struct HotKeySpec: Codable, Equatable, Sendable { keyCode: UInt32; modifiers: UInt32; static let command: UInt32 = 0x0100, shift: UInt32 = 0x0200, option: UInt32 = 0x0800, control: UInt32 = 0x1000 /* 与 Carbon 掩码同值 */; static let default = HotKeySpec(keyCode: 8, modifiers: control | option) }`；`public enum HotKeyFormat { static func display(_ s: HotKeySpec) -> String }`（修饰键顺序 ⌃⌥⇧⌘，后接按键字符；字母/数字用内置 ANSI keyCode 表，其它键显示 `Key<code>`）
  - `public enum LaunchAgent { static let label = "local.clawd.pet"; static func plist(appPath: String) -> Data }`（`ProgramArguments ["/usr/bin/open", "-g", "-a", appPath]`、`RunAtLoad true`，XML plist）；App 侧开关写入/删除 `~/Library/LaunchAgents/local.clawd.pet.plist`
  - `protocol SoundPlayer { func play(_ state: PetState) }`；`SystemSoundPlayer`：**系统音效占位**——waiting `Ping`、done `Glass`、error `Basso`（`NSSound(named:)`）
  - PetController：快照到来时 `SoundTrigger.enteredAlertStates(old:new:)`，宠物**可见**且总开关与对应状态开关都开时播放（同一批多个只播最高优先级的一个）
  - `HotKey`：Carbon `RegisterEventHotKey`，触发 → `PetController.setVisible(!visible)`；设置变化时重新注册；注册失败（被占用）在设置页显示"该快捷键已被占用"
  - `SettingsWindow`：`NSWindow` + `NSHostingController(rootView: SettingsView)`；SwiftUI `Form`：Clawd 大小（Slider，实时生效）、提示音总开关 + 三个分开关 + 灰字"系统音效占位，后续可替换"、自动合并阈值（Stepper）、全局快捷键（显示当前组合 + "录制"按钮：用本地 keyDown 监听捕获下一组至少含一个修饰键的组合；"恢复默认"）、登录时自动启动（Toggle）、重置位置（Button → `PositionModel.defaultAnchor`）；菜单栏和右键菜单的 `设置…` 打开它（激活应用并前置窗口）

- [ ] **Step 1: 写失败测试**：

```swift
@Test func launchAgentPlist() throws {
    let obj = try PropertyListSerialization.propertyList(from: LaunchAgent.plist(appPath: "/Users/u/Applications/Clawd.app"), format: nil) as! [String: Any]
    #expect(obj["Label"] as? String == "local.clawd.pet")
    #expect(obj["ProgramArguments"] as? [String] == ["/usr/bin/open", "-g", "-a", "/Users/u/Applications/Clawd.app"])
    #expect(obj["RunAtLoad"] as? Bool == true)
}
@Test func hotKeyDisplay() {
    #expect(HotKeyFormat.display(.default) == "⌃⌥C")
    #expect(HotKeyFormat.display(HotKeySpec(keyCode: 35 /* P */, modifiers: HotKeySpec.command | HotKeySpec.shift | HotKeySpec.control)) == "⌃⇧⌘P")
}
```

- [ ] **Step 2:** 运行 → 失败；**Step 3:** 实现 Core 部分 → 通过。
- [ ] **Step 4:** 实现 App 部分。
- [ ] **Step 5: 手动验证**：打开设置 → 拖大小滑块，Clawd 实时变大变小；`demo-sessions.sh` 把一个会话改成 waiting → 听到 Ping，关掉"等你确认"开关后再改 → 不响；隐藏宠物时改状态 → 不响；⌃⌥C 切换显示；录制 ⌃⌥⇧P 后旧组合失效、新组合生效；勾选开机自启 → `~/Library/LaunchAgents/local.clawd.pet.plist` 出现，`launchctl list | grep local.clawd.pet` 可见（下次登录生效），取消 → 文件消失；重置位置 → 回到右下角。
- [ ] **Step 6:** Commit `feat(app): settings, placeholder sounds, global hotkey, launch at login`

---

### Task 15: 稳定性与性能验收

**Files:**
- Modify: `scripts/measure.sh`（加 `--sessions N` 选项：先调 demo-sessions 再采样）、`README.md`（新建：安装、卸载、`/pet`、快捷键、已知限制、品牌说明）

- [ ] **Step 1: 卡死兜底**：`defaults write local.clawd.pet debugEnabled -bool true && open -g clawd://debug-hang`，等 12 s，然后 `claude -p "/pet" < /dev/null` → 输出含 `Clawd 无响应，已重启`，`pgrep -x Clawd` 的 pid 变化，宠物恢复可拖动；最后 `defaults delete local.clawd.pet debugEnabled`。
- [ ] **Step 2: 坏数据**：往 `~/.clawd/sessions/` 写一个 `{bad`、往 `~/.claude/sessions` 的副本目录（用 `CLAUDE_CONFIG_DIR` 指向临时目录启动 App）写非法 JSON → App 不崩，其余 Clawd 正常。
- [ ] **Step 3: App 不在运行时 hooks 照常工作**：`killall Clawd`；在一个会话里跑一轮对话 → `~/.clawd/sessions/` 有最新状态；`open ~/Applications/Clawd.app` → 立即显示正确状态。
- [ ] **Step 4: 性能**：`scripts/measure.sh --sessions 5`（展开，阈值调到 5）→ `phys_footprint` ≤ 50 MB，CPU 平均 < 1%；`--sessions 0` → CPU ≈ 0.0。
- [ ] **Step 5: hook 延迟**：重复 Task 5 Step 5，确认 release 版 < 30 ms。
- [ ] **Step 6:** 写 README；Commit `chore: stability checks, measurement script, README`

---

### Task 16: 三种模式端到端验收（需要用户配合）

此任务需要用户在 Desktop App 和 VS Code 里开会话，执行者逐项引导并记录结果到 `docs/superpowers/notes/2026-10-17-surface-check.md`。

- [ ] **Step 1: Desktop App**：用户在 Desktop 的 Code 页新开一个会话并发一句话。检查：(a) `~/.clawd/sessions/` 是否出现该会话（插件 hooks 是否触发）；(b) `~/.claude/sessions/` 是否有记录、`entrypoint` 值；(c) 宠物来源标签是否为 Desktop；(d) 在 Desktop 里输入 `/pet` 是否切换；(e) 关闭该会话后 claude 进程是否退出、Clawd 是否离开；(f) 点击 Clawd 是否前置 Claude.app。
  - 若 (a) 失败：按 spec §11 退路，把同样的 hooks 写进 `~/.claude/settings.json`（install.sh 增加 `--settings-hooks` 模式，uninstall 时移除），重测。
  - 若仍失败：按 spec §11 降级（只靠 registry 显示，提示"该来源暂不支持实时状态"），并在 README 已知限制中写明。
  - 若 (b) 中 `entrypoint` 不是 `claude-desktop`：更新 `SessionSource.init(entrypoint:)` 映射与测试。
- [ ] **Step 2: VS Code**：在 VS Code 的 Claude 面板里重开会话（加载插件）。检查状态流转、`/pet`、关闭面板后 Clawd 离开（`SessionEnd` 或进程退出）、点击前置正确窗口。
- [ ] **Step 3: 终端**：Terminal.app 中检查全部状态（含 Esc 打断）、`/exit`、直接关窗口、`kill -9` 三种关闭方式。
- [ ] **Step 4: 验收清单**：逐条对照 spec §13 的 1–9 项，在 notes 文件里记录通过/不通过与证据（命令输出或截图路径）。
- [ ] **Step 5:** Commit `docs: cross-surface verification results`
