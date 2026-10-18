# Critter 手机端 · 计划 1：Mac 端 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Critter.app 采集状态栏、分支和上下文数据，通过局域网把会话快照推给配对过的客户端；让客户端能回答正在等待的权限请求、提问和计划审批。做完后，用一个命令行测试客户端就能走通整条链路。

**Architecture:** hook 和 App 之间仍然只通过 `~/.critter/` 下的文件通信。新增三个子命令：`critter-hook statusline` / `ask` / `statusline-install`，`event` 也扩展了两件事。协议模型、快照组装、配对、连接状态机这些纯逻辑都放在 CritterCore 里，用单元测试覆盖。Critter.app 只做网络收发：Network.framework 的 TLS WebSocket 加 Bonjour，以及界面。

**Tech Stack:** Swift 6、SwiftPM、Swift Testing、Network.framework、CryptoKit、CoreImage（二维码）、`/usr/bin/openssl`（生成自签名证书）。不引入任何第三方依赖。

**Spec:** `docs/superpowers/specs/2026-10-18-critter-android-design.md`。执行时要和本计划对照着读。安卓端是计划 2 和计划 3，它们以本计划产出的 `docs/critter-bridge-protocol.md` 为准。

## Global Constraints

- hook 永远 exit 0。`event`、`ask` 除了合法的决策 JSON 不向 stdout 输出任何东西，所有错误都吞掉（spec §6.3、桌面 spec §3）。
- `statusline` 无论出什么错，都要原样运行原命令，并原样输出它的 stdout（spec §6.1）。
- 主线程只做界面。Bridge 跑在自己的串行队列 `local.critter.pet.bridge` 上（spec §6.5）。
- 状态文件仍是 schema 1，只能加可选字段（桌面 spec §5.1）。
- `ask` 进入等待的门槛：心跳 ≤ 10 秒、`bridgeEnabled == true`、`lastClientSeen` 在 10 分钟内。最多等 590 秒。hooks.json 里的 timeout 是 600（spec §6.3）。
- 手机连接默认关闭。默认端口 47823，被占用时依次顺延到 47832。Bonjour 服务类型是 `_critter._tcp`。只接受私有网段和回环地址的连接（spec §6.5）。
- 配对码 8 位，5 分钟内有效，只能用一次。设备令牌只存哈希。文件权限 0600，目录 0700（spec §6.5、§10）。
- 快照在 250 ms 内合并推送；单帧上限 1 MB；"发一句"最多 4000 字（spec §6.5、§7）。
- Edit/Write 这类内容只截前 4 KB 用来显示，`matchKey` 用完整内容计算（spec §6.3）。
- 默认的拒绝理由是 `用户在手机上拒绝了`（spec §6.3）。
- 本机以用户身份运行的进程不在威胁模型内（spec §10），不做代码签名校验。
- Mac 端不能改变桌面版现有的内存和 CPU 表现（spec §9）。
- 代码约定：CritterCore 里每个 `public struct` 都要有 `public` 的逐字段 `init`，可选字段的参数默认为 nil。测试里直接用这些 init，比如 `AnswerPayload(decision: "allow")`、`RateWindow(usedPercentage:resetsAt:)`。

## Review Focus

1. **settings.json 里的状态栏命令带单引号、双引号、管道、`$` 或中文路径。** 包装后终端里的输出要不变，卸载后要还原成原值。由 Task 2 的 `wrapUnwrapRoundTripsTrickyCommands` 覆盖。
2. **同一个会话里同时有两个待答请求（并行工具、子代理）。** 回答或撤销其中一个，不能误伤另一个；`Stop` 时两个都清掉。由 Task 6 的 `twoPendingInOneSessionResolveIndependently` 覆盖。
3. **在终端回答 AskUserQuestion 后，PostToolUse 的 `tool_input` 多出 `answers` 和 `annotations`，匹配键对不上。** 请求仍然要被撤销。由 Task 6 的 `terminalAnsweredQuestionStillResolves` 覆盖，用的是实测得到的真实输入。
4. **客户端回答的请求已经了结，或者回答里的问题原文不属于这个请求。** 要回 `resolved` / `invalid`，不能写回答文件。由 Task 8 的 `answerForResolvedRequestRepliesResolved` 和 `answerWithForeignQuestionIsInvalid` 覆盖。
5. **账号没有额度数据，或者最新的一份状态栏记录不带额度。** 额度取"最新的那份带额度的记录"，不能被一份不带额度的新记录清空。由 Task 7 的 `limitsComeFromNewestRecordThatHasThem` 覆盖。

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `Sources/CritterCore/CritterPaths.swift`（改） | 新增目录和文件路径 |
| `Sources/CritterCore/JSONValue.swift`（改） | 加上 `Encodable`，再加一个 `init(any:)` |
| `Sources/CritterCore/StatusLineRecord.swift` | 状态栏数据的模型、解析和存储 |
| `Sources/CritterCore/StatusLineCommand.swift` | `statusline` 子命令：记录数据，再原样转发给原命令 |
| `Sources/CritterCore/StatusLineInstaller.swift` | 包装/还原 `statusLine.command`，做文本级编辑 |
| `Sources/CritterCore/GitBranch.swift` | 从工作目录读分支 |
| `Sources/CritterCore/ContextUsage.swift` | 从会话记录末尾估算上下文用量，按模型推断窗口大小 |
| `Sources/CritterCore/PendingRequest.swift` | 待答请求和回答的模型，以及它们的文件存储 |
| `Sources/CritterCore/AskDecision.swift` | 校验回答、拼 hook 的决策 JSON、计算 `MatchKey`、截断显示内容 |
| `Sources/CritterCore/AskCommand.swift` | `ask` 子命令：判断门槛、等待、输出决策 |
| `Sources/CritterCore/Inbox.swift` | 会话收件箱地址的存储，以及发送消息 |
| `Sources/CritterCore/PendingResolution.swift` | `event` 收到哪些事件时撤销哪些请求 |
| `Sources/CritterCore/Bridge/BridgeProtocol.swift` | 客户端和服务端消息的编码、解码 |
| `Sources/CritterCore/Bridge/BridgeSnapshot.swift` | 快照模型和 `SnapshotBuilder` |
| `Sources/CritterCore/Bridge/Pairing.swift` | 配对码、配对 URI、设备登记 |
| `Sources/CritterCore/Bridge/PrivateNetwork.swift` | 判断来源地址是否在允许范围内 |
| `Sources/CritterCore/Bridge/BridgeConnection.swift` | 单个连接的协议状态机，不做任何 I/O |
| `Sources/CritterApp/Bridge/BridgeIdentity.swift` | 自签名 TLS 身份：生成、加载、计算指纹 |
| `Sources/CritterApp/Bridge/BridgeServer.swift` | NWListener、WebSocket、Bonjour，逐个收发帧 |
| `Sources/CritterApp/Bridge/BridgeController.swift` | 实现 `BridgeServices`：快照推送、各类缓存、文件监听、配对流程 |
| `Sources/CritterApp/Bridge/PhoneSettingsSection.swift` | 设置窗口里的"手机"一节和配对弹层 |
| `Sources/critter-bridge-client/main.swift` | 开发用的命令行测试客户端 |
| `scripts/dev/e2e-phone.sh` | 端到端脚本：用 tmux 驱动真实的 `claude --model haiku` |
| `docs/critter-bridge-protocol.md` | 协议说明，计划 2 和计划 3 以它为准 |

---

### Task 1: 状态栏数据采集（`critter-hook statusline`）

**Files:**
- Modify: `Sources/CritterCore/CritterPaths.swift`
- Create: `Sources/CritterCore/StatusLineRecord.swift`
- Create: `Sources/CritterCore/StatusLineCommand.swift`
- Modify: `Sources/CritterCore/HookCommand.swift`：`run` 新增路由
- Modify: `Sources/critter-hook/main.swift`：读 stdin
- Test: `Tests/CritterCoreTests/StatusLineTests.swift`

**Interfaces:**
- Produces:
  - `CritterPaths` 新增：
    - 属性 `statusDir`、`pendingDir`、`answersDir`、`inboxDir`、`bridgeDir`、`backupDir`，分别对应 `~/.critter/` 下的 `status`、`pending`、`answers`、`inbox`、`bridge`、`backup`；
    - 属性 `claudeSettingsFile`，即 `claudeHome/settings.json`；
    - 方法 `func sessionScopedFile(in dir: URL, sessionId: String) -> URL?`，复用现有的 session id 正则，不合法时返回 nil。现有的 `stateFile(sessionId:)` 改成调用它。
  - `public struct RateWindow: Codable, Sendable, Equatable { public var usedPercentage: Double; public var resetsAt: Int64 }`。`resetsAt` 的单位是毫秒，由状态栏给的秒乘以 1000。
  - `public struct StatusLineRecord: Codable, Sendable, Equatable`，字段有：
    - `sessionId: String`、`updatedAt: Int64`；
    - `modelId: String?`、`modelDisplayName: String?`；
    - `contextWindowSize: Int?`、`contextUsedPercentage: Double?`；
    - `fiveHour: RateWindow?`、`sevenDay: RateWindow?`；
    - 解析入口 `public static func parse(_ input: Data, now: Int64) -> StatusLineRecord?`，没有 `session_id` 或不是 JSON 时返回 nil。
  - `public struct StatusLineStore: Sendable`，有 `init(paths:)` 和以下方法：
    - `write(_:) throws`：原子写入；
    - `readAll() -> [StatusLineRecord]`：跳过坏文件和隐藏文件；
    - `delete(sessionId:)`。
  - `public protocol ShellRunning: Sendable { func run(command: String, stdin: Data) -> (stdout: Data, exitCode: Int32) }`，以及它的实现 `public struct SystemShell: ShellRunning`：
    - 用 `/bin/sh -c` 运行，继承环境变量；
    - stderr 直接传给自己的 stderr。
  - `public enum StatusLineCommand { public static func run(arguments: [String], stdin: Data, paths: CritterPaths, now: Int64, shell: ShellRunning) -> HookResult }`：
    - 参数形如 `["statusline", "--", "<原命令>"]`，或者只有 `["statusline"]`；
    - 退出码就是原命令的退出码，没有原命令时为 0。
  - `HookCommand.run` 新增参数 `shell: ShellRunning = SystemShell()`，并新增 `"statusline"` 分支。

- [ ] **Step 1: 写失败的测试** `Tests/CritterCoreTests/StatusLineTests.swift`

```swift
private let fullInput = #"""
{"session_id":"s1","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},
 "context_window":{"context_window_size":1000000,"used_percentage":38.2,"remaining_percentage":61.8},
 "rate_limits":{"five_hour":{"used_percentage":16,"resets_at":1792330000},
                "seven_day":{"used_percentage":39.4,"resets_at":1792800000}}}
"""#

@Test func statusLineParsesRateLimitsAndContext() {
    let r = StatusLineRecord.parse(Data(fullInput.utf8), now: 5)!
    #expect(r.sessionId == "s1" && r.updatedAt == 5)
    #expect(r.modelId == "claude-opus-5-5" && r.modelDisplayName == "Opus 5.5")
    #expect(r.contextWindowSize == 1_000_000 && r.contextUsedPercentage == 38.2)
    #expect(r.fiveHour == RateWindow(usedPercentage: 16, resetsAt: 1_792_330_000_000))
    #expect(r.sevenDay == RateWindow(usedPercentage: 39.4, resetsAt: 1_792_800_000_000))
}

@Test func statusLineMissingOrNullFieldsAreNil() {
    let r = StatusLineRecord.parse(Data(#"{"session_id":"s1","context_window":{"used_percentage":null}}"#.utf8), now: 1)!
    #expect(r.contextUsedPercentage == nil && r.fiveHour == nil && r.sevenDay == nil && r.modelId == nil)
}

@Test func statusLineCommandRunsOriginalWithSameStdin() // FakeShell 返回 ("LINE", 0)：
// 断言 shell 收到的 command == "bash /x/statusline.sh"、stdin == fullInput 的字节；
// 断言结果 == HookResult(stdout: "LINE", exitCode: 0)，并且 StatusLineStore.readAll() 里有一份 sessionId "s1" 的记录

@Test func statusLineCommandWithGarbageStdinStillRunsOriginal() // stdin "not json"：shell 仍然被调用一次，结果是 shell 的输出，没有写任何记录
@Test func statusLineWithoutOriginalPrintsNothing()             // 参数只有 ["statusline"]：结果是 HookResult(stdout: "", exitCode: 0)，记录照常写入
@Test func statusLineRejectsBadSessionId()                      // session_id 为 "../x"：不写文件，原命令照常运行
@Test func statusLinePassesOriginalExitCode()                   // FakeShell 返回 ("", 2)：exitCode == 2
```

- [ ] **Step 2: 运行，确认测试失败**

Run: `swift test --filter StatusLineTests`
Expected: 编译失败，找不到 `StatusLineRecord`。

- [ ] **Step 3: 实现 `CritterPaths` 的新增部分、`StatusLineRecord`、`StatusLineStore`、`ShellRunning`、`SystemShell`、`StatusLineCommand`，并在 `HookCommand.run` 中增加路由**

- `SystemShell` 先把 stdin 整段写进管道再关闭，然后读完 stdout。
- `main.swift` 里，`event`、`ask`、`statusline` 三个子命令都调用 `readStdin(timeoutSeconds: 2.0)`。

- [ ] **Step 4: 运行，确认测试通过**

Run: `swift test --filter StatusLineTests`
Expected: 7 个测试全部通过；`swift test` 全部通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/CritterCore Sources/critter-hook Tests/CritterCoreTests/StatusLineTests.swift
git commit -m "feat(hook): record status line data and pass it through to the user's command"
```

---

### Task 2: 包装和还原 `statusLine.command`

**Files:**
- Create: `Sources/CritterCore/StatusLineInstaller.swift`
- Modify: `Sources/CritterCore/HookCommand.swift`：新增 `statusline-install` 和 `statusline-uninstall` 路由
- Modify: `scripts/install.sh`、`scripts/uninstall.sh`
- Test: `Tests/CritterCoreTests/StatusLineInstallerTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `CritterPaths.backupDir` 和 `claudeSettingsFile`。
- Produces（App 设置页会调用这些）：

```swift
public enum StatusLineInstaller {
    public enum Failure: Error, Equatable { case unparsable, notCommandType }
    public enum Unwrapped: Equatable { case notWrapped, original(String?) }
    public enum Status: Equatable { case installed, notInstalled, otherType }
    public static func wrap(original: String?, hookPath: String) -> String
    public static func unwrap(_ command: String, hookPath: String) -> Unwrapped
    public static func install(settings: String, hookPath: String) throws -> String
    public static func uninstall(settings: String, hookPath: String) throws -> String
    public static func status(settings: String, hookPath: String) -> Status
}
```

- **包装格式**（只有这一种）：`'<hookPath>' statusline -- '<original>'`。
  - 原命令里的每个 `'` 都写成 `'\''`。
  - 没有原命令时，写成 `'<hookPath>' statusline`。
- **文本编辑的要求**：
  - 用一个只认 JSON 语法的小扫描器，找到顶层 `statusLine` 成员里 `command` 字符串字面量的字节范围，只替换这一段；新值重新编码成 JSON 字符串字面量。
  - 顶层没有 `statusLine` 时，在最后一个成员的值后面插入 `,\n<缩进>"statusLine": {"type": "command", "command": <字面量>}`。缩进取第一个成员所在行的缩进，取不到就用两个空格。
  - 卸载时：
    - 包装里没有原命令：删掉整个 `statusLine` 成员，连同它前面的逗号和空白；
    - 有原命令：只把字面量换回原值。
  - `type` 不是 `command` 时抛 `notCommandType`；扫描失败或 `JSONSerialization` 解析失败时抛 `unparsable`。
- **CLI**：`critter-hook statusline-install` / `statusline-uninstall` 读写 `claudeSettingsFile`，`hookPath` 是 `binDir/critter-hook`。
  - 写之前先把原文件复制到 `backupDir/settings.json.<now>`。
  - 原子写入，保留原文件权限。
  - 成功时打印一行中文结果，exit 0；拒绝时打印原因，exit 1。
  - 这两个子命令不是 hook，所以可以返回非 0。
- **install.sh**：在安装完 critter-hook 之后执行 `"$CRITTER_HOME/bin/critter-hook" statusline-install || echo "warning: 状态栏数据未接入" >&2`。
- **uninstall.sh**：在 `rm -rf ~/.critter` 之前执行 `"$HOME/.critter/bin/critter-hook" statusline-uninstall || true`。

- [ ] **Step 1: 写失败的测试**

```swift
private let hook = "/Users/u/.critter/bin/critter-hook"

@Test func wrapUnwrapRoundTripsTrickyCommands() {
    for original in ["bash /Users/apple/.claude/statusline-command.sh",
                     #"bash -c 'echo "hi"' | cat"#,
                     "echo $HOME && printf '%s' x",
                     "/Users/u/路径 带空格/脚本.sh"] {
        #expect(StatusLineInstaller.unwrap(StatusLineInstaller.wrap(original: original, hookPath: hook), hookPath: hook) == .original(original))
    }
    #expect(StatusLineInstaller.unwrap(StatusLineInstaller.wrap(original: nil, hookPath: hook), hookPath: hook) == .original(nil))
    #expect(StatusLineInstaller.unwrap("bash x.sh", hookPath: hook) == .notWrapped)
}

@Test func wrappedCommandRunsTheOriginalThroughTheShell()
// 用真实的 /bin/sh 验证：hookPath 换成一个打印全部参数的测试脚本，
// 执行 sh -c <wrap(original: #"echo 'a b' "c""#)>，脚本收到的 $3 必须恰好等于原命令

@Test func installReplacesOnlyTheCommandString() {
    let settings = "{\n    \"model\": \"opus\",\n    \"statusLine\": {\"type\": \"command\", \"command\": \"bash /x.sh\", \"padding\": 0},\n    \"tui\": {\"名字\": \"中文\"}\n}\n"
    let out = try! StatusLineInstaller.install(settings: settings, hookPath: hook)
    let literal = String(data: try! JSONEncoder().encode(StatusLineInstaller.wrap(original: "bash /x.sh", hookPath: hook)), encoding: .utf8)!
    #expect(out == settings.replacingOccurrences(of: "\"bash /x.sh\"", with: literal))
}

@Test func installIsIdempotent()                             // install(install(s)) == install(s)
@Test func installInsertsWhenAbsentAndUninstallRestoresBytes() // s = "{\n  \"model\": \"opus\"\n}\n"：uninstall(install(s)) == s；install 的结果用 JSONSerialization 解析后，statusLine.type == "command"
@Test func uninstallRestoresOriginalValue()                  // 原值能取回；除那一个字面量外其它字节不变
@Test func installRefusesNonCommandType()                    // "statusLine": {"type": "static"} 时抛 .notCommandType
@Test func installRefusesUnparsable()                        // "{ not json" 时抛 .unparsable
@Test func statusReportsEachCase()                           // .installed / .notInstalled / .otherType
@Test func cliInstallWritesBackupAndSettings()               // 用临时的 CLAUDE_CONFIG_DIR 和 CRITTER_HOME：结果 exitCode 0，backupDir 里有一份和原文件相同的备份
```

- [ ] **Step 2: 运行，确认测试失败**

Run: `swift test --filter StatusLineInstallerTests`
Expected: 编译失败。

- [ ] **Step 3: 按上面的格式和要求实现 `StatusLineInstaller` 和两个 CLI 子命令，并修改 install.sh 和 uninstall.sh**

- [ ] **Step 4: 运行，确认测试通过**

Run: `swift test --filter StatusLineInstallerTests && swift test`
Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/CritterCore Tests/CritterCoreTests/StatusLineInstallerTests.swift scripts/install.sh scripts/uninstall.sh
git commit -m "feat(install): wrap the user's status line so Critter can read its data"
```

---

### Task 3: git 分支与上下文兜底

**Files:**
- Create: `Sources/CritterCore/GitBranch.swift`
- Create: `Sources/CritterCore/ContextUsage.swift`
- Test: `Tests/CritterCoreTests/GitBranchTests.swift`、`Tests/CritterCoreTests/ContextUsageTests.swift`

**Interfaces:**
- Produces:
  - `public enum GitBranch { public static func read(cwd: String, stopAt home: String) -> String? }`
    - 从 `cwd` 开始逐级往上找 `.git`，到 `home` 或根目录为止。
    - `.git` 是文件时，跟着 `gitdir: <path>` 找；相对路径相对 `.git` 所在目录解析。
    - `HEAD` 是 `ref: refs/heads/X` 时返回 X；是 40 位十六进制时返回前 7 位；其它情况返回 nil。
  - `public struct ContextEstimate: Equatable, Sendable { public var usedTokens: Int; public var model: String? }`
  - `public enum ContextUsage`：
    - `static func lastUsage(inTranscriptTail tail: Data) -> ContextEstimate?`：
      - 丢掉第一行（可能被截断）和最后一个不完整的行；
      - 从后往前找第一条 `type == "assistant"`、并且 `message.usage` 存在的行；
      - `usedTokens = input_tokens + cache_creation_input_tokens + cache_read_input_tokens`，缺的项按 0 算；
      - `model = message.model`。
    - `static func windowSize(forModel model: String?) -> Int`：
      - 模型 id 含 `[1m]`，或者以 `claude-fable-`、`claude-sonnet-5`、`claude-haiku-5-5`、`claude-opus-4-7`、`claude-opus-5` 中任意一个开头时，返回 1_000_000；
      - 其它情况，包括 nil，返回 200_000。
    - `static func percent(usedTokens: Int, windowSize: Int) -> Double`：返回 0…100，保留一位小数。

- [ ] **Step 1: 写失败的测试**

```swift
@Test func branchFromNormalRepo()        // 临时目录/.git/HEAD = "ref: refs/heads/feat/login\n"，cwd 是 repo/a/b → "feat/login"
@Test func branchDetachedIsShortSha()     // HEAD = 40 位十六进制 → 前 7 位
@Test func branchFollowsWorktreeGitFile() // repo-wt/.git 是文件，内容 "gitdir: ../main/.git/worktrees/wt"，那里的 HEAD 指向 refs/heads/wt → "wt"
@Test func branchNilOutsideRepo()
@Test func branchStopsAtHome()            // .git 在 home 的上一级 → nil
@Test func branchNilForGarbageHead()

@Test func usageFromLastAssistantLine() {
    let tail = """
    partial-line-cut-off"}
    {"type":"assistant","message":{"model":"claude-haiku-5-5","usage":{"input_tokens":1,"cache_read_input_tokens":2}}}
    {"type":"user","message":{"content":"hi"}}
    {"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_creation_input_tokens":200,"cache_read_input_tokens":5000,"output_tokens":99}}}

    """
    #expect(ContextUsage.lastUsage(inTranscriptTail: Data(tail.utf8)) == ContextEstimate(usedTokens: 5210, model: "claude-opus-5-5"))
}
@Test func usageNilWithoutAssistantUsage()
@Test func windowSizesByModel() // "claude-opus-5-5" → 1_000_000；"claude-sonnet-4-6" → 200_000；"claude-sonnet-4-6[1m]" → 1_000_000；nil → 200_000
@Test func percentRounds()      // percent(usedTokens: 5210, windowSize: 200_000) == 2.6
```

- [ ] **Step 2: 运行，确认测试失败**

Run: `swift test --filter GitBranchTests && swift test --filter ContextUsageTests`
Expected: 编译失败。

- [ ] **Step 3: 实现 `GitBranch` 和 `ContextUsage`**

- [ ] **Step 4: 运行，确认测试通过**

Run: `swift test --filter "GitBranchTests|ContextUsageTests"`
Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/CritterCore/GitBranch.swift Sources/CritterCore/ContextUsage.swift Tests/CritterCoreTests/GitBranchTests.swift Tests/CritterCoreTests/ContextUsageTests.swift
git commit -m "feat(core): read git branches and estimate context usage from transcripts"
```

---

### Task 4: 待答请求、回答和决策 JSON

**Files:**
- Modify: `Sources/CritterCore/JSONValue.swift`
- Create: `Sources/CritterCore/PendingRequest.swift`
- Create: `Sources/CritterCore/AskDecision.swift`
- Test: `Tests/CritterCoreTests/PendingStoreTests.swift`、`Tests/CritterCoreTests/AskDecisionTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `CritterPaths.pendingDir`、`answersDir`、`sessionScopedFile`。
- Produces:
  - `JSONValue` 改成同时遵守 `Encodable`（`Codable`），再加上 `public init(any: Any?)`：把 `JSONSerialization` 的产物转换过来，`NSNumber` 里的布尔值要转成 `.bool`。
  - `public enum PendingKind: String, Codable, Sendable { case permission, question, plan; public init(toolName: String) }`：`AskUserQuestion` 对应 `.question`，`ExitPlanMode` 对应 `.plan`，其余都是 `.permission`。
  - `public struct PendingRequest: Codable, Sendable, Equatable`，字段有：
    - `requestId`、`sessionId`；
    - `kind: PendingKind`；
    - `toolName`；
    - `summary: String`：权限请求用 `ToolSummary.permission(...)`，提问和计划分别用 `BubbleText.askQuestion` 和 `BubbleText.planApproval`；
    - `input: JSONValue`：只用来显示，已截断；
    - `matchKey`；
    - `createdAt`、`expiresAt: Int64`；
    - `hookPid: Int32`。
  - `public struct AnswerPayload: Codable, Sendable, Equatable { public var decision: String?; public var message: String?; public var answers: [String: String]? }`
  - `public struct PendingStore: Sendable`，有 `init(paths:)` 和以下方法：
    - `write(_:) throws`：目录 0700，文件 0600；
    - `readAll() -> [PendingRequest]`；
    - `read(requestId:) -> PendingRequest?`；
    - `remove(requestId:)`：同时删掉对应的回答文件；
    - `removeAll(sessionId:)`；
    - `removeMatching(sessionId:toolName:matchKey:)`；
    - `writeAnswer(_:requestId:) throws`：目录 0700，文件 0600；
    - `readAnswer(requestId:) -> AnswerPayload?`；
    - `sweep(now: Int64, isAlive: (Int32) -> Bool)`：删掉过期的请求、hook 进程已经不在的请求，以及没有对应请求的回答文件。
    - requestId 用和 session id 一样的正则校验。
  - `public enum MatchKey { public static func compute(toolName: String, toolInput: Any?) -> String }`：
    - 对 `toolName + "\n" + JSONSerialization(toolInput, [.sortedKeys, .withoutEscapingSlashes])` 计算 SHA-256，输出小写十六进制。
    - `toolInput` 为 nil 时，序列化部分用空串。
  - `public enum AskDecision`：
    - `static let defaultDenyMessage = "用户在手机上拒绝了"`；
    - `static let untruncatedKeys: Set<String> = ["command", "plan", "question", "file_path", "notebook_path", "url"]`；
    - `static func displayInput(_ toolInput: Any?) -> JSONValue`：所有长度超过 4096 的字符串截成 4096 个字符再加 `…`，但键名在 `untruncatedKeys` 里的不截；
    - `static func validate(_ answer: AnswerPayload, kind: PendingKind, toolInput: [String: Any]) -> Bool`；
    - `static func output(kind: PendingKind, toolInput: [String: Any], answer: AnswerPayload) -> Data?`：回答不合法时返回 nil。
  - 校验规则：
    - **permission**：`decision` ∈ {allow, deny}；
    - **question**：`answers` 不能为空；每个键都必须是 `toolInput.questions[*].question` 里的原文；每个值去掉首尾空白后不能为空，而且不超过 4000 字；
    - **plan**：`decision` ∈ {approve, revise}；revise 时 `message` 去掉首尾空白后不能为空。
  - 输出（`JSONSerialization`，`updatedInput` 原样带回 `toolInput` 里的所有值）：

| kind | 回答 | 输出 |
|---|---|---|
| permission | `decision` 为 allow | `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` |
| permission | `decision` 为 deny | `behavior` 为 `"deny"`；`message` 去掉首尾空白后为空时，换成 `defaultDenyMessage` |
| question | `answers` | `behavior` 为 `"allow"`；`updatedInput` = toolInput 加上 `"answers": answers` |
| plan | `decision` 为 approve | `behavior` 为 `"allow"`；`updatedInput` = toolInput |
| plan | `decision` 为 revise | `behavior` 为 `"deny"`；`message` 就是回答里的 message |

- [ ] **Step 1: 写失败的测试**。测试数据是 2026-10-18 实验时记录下来的真实 `tool_input`。

```swift
private let bashInput: [String: Any] = ["command": "touch reject-me.txt", "description": "Create empty file reject-me.txt"]
private let questionInput: [String: Any] = try! JSONSerialization.jsonObject(with: Data(#"""
{"questions":[{"question":"Pick a number","header":"Number","options":[{"label":"One","description":"Choose option One"},{"label":"Two","description":"Choose option Two"}],"multiSelect":false}]}
"""#.utf8)) as! [String: Any]
private let planInput: [String: Any] = ["plan": "# Plan: create plan-marker-2.txt\n\n## Steps\n1. Run `touch plan-marker-2.txt`.\n", "planFilePath": "/Users/u/.claude/plans/x.md"]

@Test func permissionAllowOutput() {
    let out = AskDecision.output(kind: .permission, toolInput: bashInput, answer: AnswerPayload(decision: "allow"))!
    #expect(json(out) == json(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#))
}
@Test func permissionDenyUsesDefaultMessageWhenBlank()  // decision deny、message "  " → message == "用户在手机上拒绝了"
@Test func questionOutputEchoesInputPlusAnswers() {
    let out = AskDecision.output(kind: .question, toolInput: questionInput, answer: AnswerPayload(answers: ["Pick a number": "Two"]))!
    let d = json(out)["hookSpecificOutput"]["decision"]
    #expect(d["behavior"] == "allow")
    #expect(d["updatedInput"]["questions"] == JSONValue(any: questionInput["questions"]))
    #expect(d["updatedInput"]["answers"] == .object(["Pick a number": .string("Two")]))
}
@Test func questionFreeTextIsAccepted()                // answers ["Pick a number": "Mango"] 合法
@Test func answerWithUnknownQuestionIsRejected()       // ["Other?": "x"] → validate == false，output == nil
@Test func planApproveEchoesInput()                    // updatedInput == JSONValue(any: planInput)
@Test func planReviseNeedsMessage()                    // message 为空 → nil；message "改名为 x" → behavior "deny"，message "改名为 x"
@Test func wrongDecisionForKindIsRejected()            // permission + approve → nil；plan + allow → nil
@Test func matchKeyIgnoresKeyOrder()                   // ["a":1,"b":2] 和 ["b":2,"a":1] 的 key 相同；换一个 toolName 后 key 不同
@Test func displayInputTruncatesLongContentButNotCommand() // content 为 5000 个 "x" → 4096 个 x 加 "…"；同样长度的 command 原样保留
@Test func storeRoundTripAndPermissions()             // write 后用 read 读回；文件权限 0o600，目录权限 0o700
@Test func storeRemoveMatchingTouchesOnlyThatSessionAndKey()
@Test func sweepDropsExpiredDeadAndOrphans()          // expiresAt < now 的删掉；isAlive 返回 false 的删掉；没有对应请求的回答文件删掉；其余的保留
```

（`json(_:)` 是测试文件里的小工具，作用是把 `Data` 或 `String` 解码成 `JSONValue`。）

- [ ] **Step 2: 运行，确认测试失败**

Run: `swift test --filter "PendingStoreTests|AskDecisionTests"`
Expected: 编译失败。

- [ ] **Step 3: 实现 `JSONValue` 的改动、`PendingRequest.swift`、`AskDecision.swift`**

- [ ] **Step 4: 运行，确认测试通过**

Run: `swift test`
Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/CritterCore Tests/CritterCoreTests/PendingStoreTests.swift Tests/CritterCoreTests/AskDecisionTests.swift
git commit -m "feat(core): pending requests, answers and the hook decisions built from them"
```

---

### Task 5: `critter-hook ask`

**Files:**
- Modify: `Sources/CritterCore/AppStatus.swift`
- Create: `Sources/CritterCore/AskCommand.swift`
- Modify: `Sources/CritterCore/HookCommand.swift`：新增 `ask` 路由
- Modify: `plugin/hooks/hooks.json`、`plugin/.claude-plugin/plugin.json`、`.claude-plugin/marketplace.json`：版本号改为 `0.3.0`
- Test: `Tests/CritterCoreTests/AskCommandTests.swift`、`Tests/CritterHookTests/HookBinaryTests.swift`（新增一个测试）

**Interfaces:**
- Consumes: Task 4 的 `PendingStore`、`PendingRequest`、`AskDecision`、`MatchKey`、`PendingKind`。
- Produces:
  - `AppStatus` 新增两个可选字段 `bridgeEnabled: Bool?` 和 `lastClientSeen: Int64?`（毫秒）。`init` 里给它们默认值 nil。
  - `public enum AskGate`：
    - `static let heartbeatFreshMs: Int64 = 10_000`；
    - `static let clientRecentMs: Int64 = 600_000`；
    - `static func shouldStart(status: AppStatus?, now: Int64) -> Bool`：三个条件都满足才返回 true；
    - `static func shouldKeepWaiting(status: AppStatus?, now: Int64) -> Bool`：只看心跳和 `bridgeEnabled`。
  - `public struct AskEnvironment: Sendable`，字段有：
    - `now: @Sendable () -> Int64`；
    - `sleep: @Sendable (TimeInterval) -> Void`；
    - `ownPid: Int32`；
    - `newRequestId: @Sendable () -> String`；
    - `maxWaitMs: Int64 = 590_000`；
    - `pollInterval: TimeInterval = 0.2`；
    - 一个静态的 `live` 实例。
  - `public enum AskCommand { public static func run(stdin: Data, paths: CritterPaths, env: AskEnvironment) -> HookResult }`
- `hooks.json`：在 `PermissionRequest` 的 `hooks` 数组里，紧跟在现有的 `event` 项后面加一项。命令写法和现有的完全一样，只是把子命令换成 `ask`，`"timeout": 600`。

- [ ] **Step 1: 写失败的测试**。测试里用一个虚拟时钟：`sleep` 推进时钟，并调用一个由测试注入的回调，用这个回调来扮演 App。

```swift
@Test func askExitsImmediatelyWhenGateClosed()
// 依次构造四种情况：没有 app.json；心跳是 11 秒前；bridgeEnabled 为 false；lastClientSeen 是 11 分钟前。
// 每种情况下，结果都是 HookResult(stdout: "", exitCode: 0)，pendingDir 里没有文件，sleep 一次都没被调用

@Test func askOutputsAllowWhenAnswered()
// 门槛满足；第一次 sleep 时测试写入回答 AnswerPayload(decision: "allow")。
// 结果的 stdout 解码后等于 permissionAllowOutput 的那份 JSON；请求和回答两个文件都被删掉

@Test func askWritesPendingWithDisplayInputAndMatchKey()
// 在第一次 sleep 时读取 pending 文件：kind == .permission，matchKey == MatchKey.compute(toolName: "Bash", toolInput: bashInput)，
// expiresAt == createdAt + 590_000，hookPid == env.ownPid

@Test func askQuestionOutputsUpdatedInputWithAnswers()
@Test func askPlanReviseOutputsDenyWithMessage()
@Test func askStopsSilentlyWhenPendingRemoved()      // 测试在 sleep 时删掉 pending → stdout 为 ""
@Test func askStopsWhenHeartbeatGoesStale()           // 测试在 sleep 时把心跳改旧 → stdout 为 ""，pending 被删
@Test func askStopsWhenBridgeDisabledMidWait()
@Test func askGivesUpAtDeadline()                     // maxWaitMs 设为 1_000 → stdout 为 ""，pending 被删
@Test func askIgnoresInvalidAnswerAndKeepsWaiting()   // 先写入 {decision:"approve"}（对权限请求不合法），它会被删掉；再写入 allow → 输出 allow
@Test func askWithGarbageStdinExitsSilently()
```

在 `HookBinaryTests.swift` 里新增：

```swift
@Test func binaryAskWithoutAppExitsFast() // 跑真实的二进制，CRITTER_HOME 指向空目录：1 秒内退出，stdout 为空，退出码 0
```

- [ ] **Step 2: 运行，确认测试失败**

Run: `swift test --filter "AskCommandTests|HookBinaryTests"`
Expected: 编译失败。

- [ ] **Step 3: 实现 `AppStatus` 的新字段、`AskGate`、`AskEnvironment`、`AskCommand`、`ask` 路由；修改 hooks.json，并把两处版本号改成 0.3.0**

`AskCommand.run` 的流程：
1. 解码 stdin（`JSONSerialization`），要求 `hook_event_name == "PermissionRequest"`，并且有 `session_id`、`tool_name`、`tool_input`。不满足就返回空结果。
2. 判断 `AskGate.shouldStart`，不满足就返回空结果。
3. 写入 pending 文件。
4. 循环：调用 `sleep(pollInterval)`，然后按以下顺序检查：
   - 回答文件；
   - pending 文件还在不在；
   - `shouldKeepWaiting`；
   - 是否到了截止时间。
5. 所有退出路径都确保 pending 和回答文件已删除，除非 pending 本来就已经被别人删了。

- [ ] **Step 4: 运行，确认测试通过**

Run: `swift test`
Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/CritterCore Tests plugin .claude-plugin
git commit -m "feat(hook): let a paired phone answer permission prompts, questions and plans"
```

---

### Task 6: `event` 钩子：撤销已了结的请求，记录收件箱

**Files:**
- Create: `Sources/CritterCore/PendingResolution.swift`
- Create: `Sources/CritterCore/Inbox.swift`
- Modify: `Sources/CritterCore/HookCommand.swift`：`runEvent`
- Test: `Tests/CritterCoreTests/PendingResolutionTests.swift`、`Tests/CritterCoreTests/InboxTests.swift`

**Interfaces:**
- Consumes: Task 4 的 `PendingStore` 和 `MatchKey`。
- Produces:
  - `public enum PendingResolution { public static func apply(event: String, sessionId: String, toolName: String?, toolInput: Any?, store: PendingStore) }`，规则如下：
    - `PostToolUse` / `PostToolUseFailure` / `PermissionDenied`：
      - 先执行 `removeMatching(sessionId, toolName, MatchKey.compute(toolName, toolInput))`；
      - 如果 `toolName` 是 `AskUserQuestion` 或 `ExitPlanMode`，再把这个会话里所有同名工具的请求都删掉，因为终端作答后 `tool_input` 会多出 `answers` / `annotations`。
    - `UserPromptSubmit` / `Stop` / `StopFailure` / `SessionEnd`：`removeAll(sessionId)`。
    - 其它事件不做任何处理。
  - `public struct InboxRecord: Codable, Sendable, Equatable { public var sessionId: String; public var socketPath: String; public var token: String }`
  - `public struct InboxStore: Sendable`，有 `init(paths:)` 和以下方法：
    - `write(_:) throws`：目录 0700，文件 0600；
    - `read(sessionId:) -> InboxRecord?`；
    - `delete(sessionId:)`。
  - `public enum InboxSender`：
    - `public enum Failure: Error, Equatable { case notAllowedPath, connectFailed, writeFailed }`；
    - `public static let allowedPath = #"^(/private)?/tmp/cc-socks(-[0-9]+)?/[^/]+\.sock$"#`；
    - `public static func send(text: String, to record: InboxRecord) throws`：
      - 连接 Unix 域 socket，先写一行 `{"type":"auth","token":…}`，再写一行 `{"type":"user","message":{"role":"user","content":…}}`，然后关闭；
      - 每行都用 `JSONSerialization` 编码，以 `\n` 结尾；
      - 不等待回执。
- `runEvent` 的新增部分：
  - 在已有的状态写入之后，再用 `JSONSerialization` 解析一次 stdin，取出 `tool_input`，调用 `PendingResolution.apply`。
  - `SessionStart` 时，如果环境变量里 `CLAUDE_CODE_MESSAGING_SOCKET` 和 `CLAUDE_CODE_MESSAGING_TOKEN` 都不为空，就写入 `InboxRecord`。
  - `SessionEnd` 时删除收件箱记录，同时调用 `StatusLineStore.delete(sessionId:)` 删掉这个会话的状态栏数据。
  - 新增部分抛出的任何错误都吞掉；stdout 仍然为空。

- [ ] **Step 1: 写失败的测试**

```swift
@Test func postToolUseResolvesMatchingRequestOnly()
@Test func twoPendingInOneSessionResolveIndependently()
// 同一会话有两个请求：Bash "a" 和 Bash "b"。PostToolUse(Bash "a") 之后只剩 "b"；Stop 之后一个都不剩；另一个会话的请求不受影响

@Test func terminalAnsweredQuestionStillResolves()
// pending 的 matchKey 用的是 questionInput；PostToolUse 的 tool_input 是实测得到的 questionInput 加上
// "answers":{"Pick a number":"One"} 和 "annotations":{} → 请求被删掉

@Test func userPromptSubmitClearsSession()
@Test func eventStillPrintsNothing()        // 跑一遍 HookCommand.run(["event"], ...)，PostToolUse → stdout 为 ""

@Test func sessionStartWritesInboxFromEnvironment()
// environment 里设置两个变量 → InboxStore.read 能读回；文件权限 0o600
@Test func sessionStartWithoutEnvironmentWritesNothing()
@Test func sessionEndDeletesInboxAndStatus() // 收件箱记录和状态栏数据文件都被删掉

@Test func senderWritesAuthThenUserLine()
// 在 /tmp/cc-socks-9<随机数字>/t.sock 起一个测试用的 Unix 服务端，读到 EOF。
// 收到的内容恰好是两行，第一行 type 为 auth、token 正确，第二行 message.content 为 "你好"
@Test func senderRejectsPathOutsideCcSocks() // "/tmp/evil.sock" → 抛 .notAllowedPath
```

- [ ] **Step 2: 运行，确认测试失败**

Run: `swift test --filter "PendingResolutionTests|InboxTests"`
Expected: 编译失败。

- [ ] **Step 3: 实现 `PendingResolution`、`Inbox.swift`，并修改 `runEvent`**

- [ ] **Step 4: 运行，确认测试通过**

Run: `swift test`
Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/CritterCore Tests/CritterCoreTests
git commit -m "feat(hook): clear answered requests and remember each session's inbox"
```

---

### Task 7: 协议模型、快照组装、配对、网段过滤，以及协议文档

**Files:**
- Create: `Sources/CritterCore/Bridge/BridgeProtocol.swift`
- Create: `Sources/CritterCore/Bridge/BridgeSnapshot.swift`
- Create: `Sources/CritterCore/Bridge/Pairing.swift`
- Create: `Sources/CritterCore/Bridge/PrivateNetwork.swift`
- Create: `docs/critter-bridge-protocol.md`
- Test: `Tests/CritterCoreTests/BridgeProtocolTests.swift`、`SnapshotBuilderTests.swift`、`PairingTests.swift`、`PrivateNetworkTests.swift`

**Interfaces:**
- Consumes: `PetSession`、`StatusLineRecord`、`RateWindow`、`PendingRequest`、`AnswerPayload`、`ContextEstimate`、`ContextUsage`。
- Produces:

```swift
public enum BridgeProtocol { public static let version = 1; public static let maxFrameBytes = 1_048_576; public static let maxSayChars = 4000; public static let defaultPort: UInt16 = 47823; public static let portRange: ClosedRange<UInt16> = 47823...47832; public static let bonjourType = "_critter._tcp" }

public enum ClientMessage: Equatable, Sendable {
    case hello(protocolVersion: Int, deviceId: String, token: String, app: String)
    case pair(code: String, deviceName: String)
    case answer(id: String?, requestId: String, payload: AnswerPayload)
    case seen(id: String?, sessionId: String)
    case say(id: String?, sessionId: String, text: String)
    case skin(id: String?, name: String)
    public static func decode(_ frame: Data) -> ClientMessage?
    public func encode() -> Data            // 测试客户端用
}
public enum ServerMessage: Equatable, Sendable {
    case welcome(macName: String, version: String)
    case paired(deviceId: String, token: String, macName: String)
    case denied(reason: DenyReason)          // badToken | badCode | rejected | protocol
    case snapshot(seq: Int, sentAt: Int64, body: SnapshotBody)
    case skin(id: String?, name: String, manifest: JSONValue?)
    case result(id: String?, ok: Bool, reason: ResultReason?, message: String?)   // reason: resolved | invalid | expired | unavailable | failed
    public func encode() -> Data
    public static func decode(_ frame: Data) -> ServerMessage?   // 测试客户端用
}
public struct SnapshotBody: Codable, Equatable, Sendable { public var sessions: [BridgeSession]; public var limits: BridgeLimits?; public var pending: [BridgePending]; public var prefs: BridgePrefs }
public struct BridgeSession: Codable, Equatable, Sendable { id, name: String; source: SessionSource; state: PetState; detail, activity: String?; cwd: String; branch, model: String?; context: BridgeContext?; skin: String; eventTime, startedAt: Int64; tracked: Bool }
public struct BridgeContext: Codable, Equatable, Sendable { usedPercent: Double; windowSize: Int; estimated: Bool }
public struct BridgeLimits: Codable, Equatable, Sendable { fiveHour, sevenDay: RateWindow?; updatedAt: Int64 }
public struct BridgePending: Codable, Equatable, Sendable { requestId, sessionId: String; kind: PendingKind; toolName, summary: String; input: JSONValue; createdAt, expiresAt: Int64 }
public struct BridgePrefs: Codable, Equatable, Sendable { skin: String; randomSkins: Bool; idleDim: Double; mergeThreshold: Int }
public struct SnapshotInputs: Sendable { sessions: [PetSession]; skins: [String: String]; statuses: [StatusLineRecord]; pending: [PendingRequest]; branches: [String: String]; estimates: [String: ContextEstimate]; prefs: BridgePrefs; home: String }
public enum SnapshotBuilder { public static func build(_ inputs: SnapshotInputs) -> SnapshotBody }

public struct PairingCode: Equatable, Sendable { public let code: String; public let expiresAt: Int64
    public static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789"); public static let length = 8; public static let lifetimeMs: Int64 = 300_000
    public static func generate(now: Int64) -> PairingCode }
public struct PairingURI: Equatable, Sendable { host: String; port: UInt16; fingerprint: String; code: String; name: String
    public var string: String          // critter-pair://<host>:<port>?fp=<64 位小写十六进制>&code=<code>&name=<百分号编码>（IPv6 主机加方括号）
    public init?(string: String) }
public struct DeviceRecord: Codable, Equatable, Sendable { id, name, tokenHash: String; pairedAt: Int64; lastSeen: Int64? }
public final class DeviceRegistry: @unchecked Sendable {   // 内部加锁
    public init(file: URL)
    public func list() -> [DeviceRecord]
    public func add(name: String, now: Int64) throws -> (record: DeviceRecord, token: String)   // token = 32 个随机字节的 base64url；文件权限 0600
    public func verify(deviceId: String, token: String) -> DeviceRecord?                       // 比较 SHA-256 哈希，用定长时间比较
    public func touch(deviceId: String, now: Int64)
    public func revoke(deviceId: String)
    public func removeAll() }
public enum PrivateNetwork { public static func isAllowed(host: String) -> Bool }
```

- **`SnapshotBuilder` 的规则**：
  - 会话顺序沿用输入的顺序。
  - `cwd` 以 `home` 开头时，把这部分换成 `~`。
  - `skin` 取 `skins[id]`，没有时用 `prefs.skin`。
  - `branch` 取 `branches[cwd]`。
  - `model`：先用这个会话状态栏记录里的 `modelDisplayName`，没有就用 `estimates[id]?.model`，再没有就是 nil。
  - `context`：
    - 状态栏记录里有 `contextUsedPercentage` 时，用它，`windowSize` 取记录里的 `contextWindowSize`，没有就按 `ContextUsage.windowSize(model)` 推断，`estimated` 为 false；
    - 否则有估算值时，用 `ContextUsage.percent`，窗口大小的取法同上，`estimated` 为 true；
    - 都没有时为 nil。
  - `limits`：在所有 `fiveHour` 或 `sevenDay` 不为 nil 的状态栏记录里，取 `updatedAt` 最大的那一份；一份都没有时为 nil。
  - `pending`：只保留 `sessionId` 在会话列表里的请求，按 `createdAt` 升序排列。
- **`PrivateNetwork.isAllowed` 的允许范围**：
  - IPv4：10/8、172.16/12、192.168/16、169.254/16、100.64/10、127/8。
  - IPv6：::1、fe80::/10、fc00::/7，以及 IPv4 映射地址（按里面的 IPv4 判断）。
  - 判断前去掉 `%scope` 后缀。
- **协议文档 `docs/critter-bridge-protocol.md`**：给每种消息写一个完整的 JSON 示例，字段名和 Swift 的编码结果逐字一致。要写明的约定有：
  - 所有时间都是毫秒；
  - 枚举的取值；
  - 每个可选字段缺省时代表什么；
  - TLS 指纹指的是证书 DER 编码的 SHA-256；
  - 连接流程：先发 `hello` 或 `pair` → 收到 `welcome` / `paired` → 收到 `snapshot`；
  - 心跳用 WebSocket 的 ping。

  计划 2 的 Kotlin 模型以这份文档为准。

- [ ] **Step 1: 写失败的测试**

```swift
@Test func clientMessagesRoundTrip()     // 每种消息先 encode 再 decode，得到原值
@Test func decodeRejectsUnknownOrMalformed() // {"type":"nope"}、缺少字段、不是 JSON → nil
@Test func serverSnapshotEncodesDocumentedShape()
// 固定一个快照，encode 后用 JSONSerialization 读出来，逐个检查键名：
// type、seq、sentAt、sessions[0].context.usedPercent、limits.fiveHour.resetsAt、pending[0].input.command、prefs.mergeThreshold

@Test func snapshotUsesStatusLineContextOverEstimate()
@Test func snapshotFallsBackToEstimateMarkedEstimated()
// 状态栏没有数据；估算值 ContextEstimate(5210, "claude-opus-5-5") → context == BridgeContext(usedPercent: 0.5, windowSize: 1_000_000, estimated: true)
@Test func limitsComeFromNewestRecordThatHasThem()
// 三份记录：A(updatedAt 10，带额度)、B(updatedAt 30，带额度)、C(updatedAt 50，不带额度) → 取 B
@Test func snapshotTildesHomeAndPicksSkin()
@Test func pendingOfUnknownSessionIsDropped()

@Test func pairingCodeShapeAndExpiry()   // 8 个字符，全部来自 alphabet；expiresAt == now + 300_000
@Test func pairingURIRoundTrip()         // 包括 IPv6 主机和中文电脑名
@Test func registryAddVerifyRevoke()     // add 返回的 token 能通过 verify；token 错误时返回 nil；revoke 之后返回 nil；文件里不出现 token 明文
@Test func privateNetworkTable()
// 允许："192.168.1.5"、"10.0.0.2"、"172.31.255.1"、"127.0.0.1"、"fe80::1%en0"、"::ffff:192.168.1.5"
// 拒绝："8.8.8.8"、"172.32.0.1"、"2001:db8::1"、"::ffff:8.8.8.8"、"garbage"
```

- [ ] **Step 2: 运行，确认测试失败**

Run: `swift test --filter "BridgeProtocolTests|SnapshotBuilderTests|PairingTests|PrivateNetworkTests"`
Expected: 编译失败。

- [ ] **Step 3: 实现上面四个文件，并写 `docs/critter-bridge-protocol.md`**

- [ ] **Step 4: 运行，确认测试通过**

Run: `swift test`
Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/CritterCore/Bridge Tests/CritterCoreTests docs/critter-bridge-protocol.md
git commit -m "feat(core): bridge protocol, snapshots and pairing"
```

---

### Task 8: 连接状态机 `BridgeConnection`（纯逻辑）

**Files:**
- Create: `Sources/CritterCore/Bridge/BridgeConnection.swift`
- Test: `Tests/CritterCoreTests/BridgeConnectionTests.swift`

**Interfaces:**
- Consumes: Task 7 的消息类型、`DeviceRecord`；Task 4 的 `PendingRequest`、`AskDecision.validate`。
- Produces（Task 9 的 `BridgeController` 实现这个协议，`BridgeServer` 驱动这个状态机）：

```swift
public enum SayOutcome: Equatable, Sendable { case sent, unavailable, failed }
public protocol BridgeServices: AnyObject {
    var macName: String { get }
    var version: String { get }
    func verify(deviceId: String, token: String) -> DeviceRecord?
    func consumePairingCode(_ code: String) -> Bool
    func pendingRequest(_ requestId: String) -> PendingRequest?
    func originalToolInput(_ requestId: String) -> [String: Any]?   // 校验用：从 pending 文件的 input 还原，问题原文完整保留
    func submitAnswer(_ payload: AnswerPayload, requestId: String) -> Bool
    func markSeen(sessionId: String)
    func say(text: String, sessionId: String) -> SayOutcome
    func skinManifest(name: String) -> JSONValue?
    func snapshotMessage() -> ServerMessage
}
public final class BridgeConnection {
    public enum Phase: Equatable { case awaitingFirst, awaitingApproval(deviceName: String), ready(deviceId: String), closed }
    public enum Output: Equatable { case send(ServerMessage), close }
    public private(set) var phase: Phase
    public init(services: BridgeServices)
    public func receive(_ frame: Data) -> [Output]
    public func approvePairing(deviceId: String, token: String) -> [Output]   // → paired、welcome、快照
    public func rejectPairing() -> [Output]                                   // → denied(.rejected)、close
    public func broadcast(_ snapshot: ServerMessage) -> [Output]              // 只有 ready 时才发
}
```

- **规则**：
  - 超过 `maxFrameBytes` 的帧：直接关闭连接。
  - 处于 `awaitingFirst` 时：
    - 无法解码、或者不是 hello / pair：回 `denied(.protocol)` 并关闭；
    - hello 的版本号不对：回 `denied(.protocol)` 并关闭；
    - hello 的令牌错误：回 `denied(.badToken)` 并关闭；
    - hello 正确：回 `welcome` 和快照，进入 `ready`；
    - pair 的码错误：回 `denied(.badCode)` 并关闭；
    - pair 的码正确：进入 `awaitingApproval`，暂时不回任何东西。
  - 处于 `awaitingApproval` 时，收到任何帧都忽略。
  - 处于 `ready` 时：
    - **answer**：请求不存在时回 `result(reason: .resolved, message: "已在电脑上处理")`；`AskDecision.validate` 不通过时回 `.invalid`；`submitAnswer` 返回 false 时回 `.failed`；成功回 ok。
    - **seen**：调用 `markSeen`，回 ok。
    - **say**：文字去掉首尾空白后为空，或者超过 4000 字时回 `.invalid`；否则按 `SayOutcome` 分别回 ok、`.unavailable`、`.failed`。
    - **skin**：回 `skin` 消息。
    - 无法解码的帧：忽略，不关闭连接。

- [ ] **Step 1: 写失败的测试**。测试里的 `FakeServices` 会记录所有调用。

```swift
@Test func helloWithGoodTokenGetsWelcomeAndSnapshot()
@Test func helloWithBadTokenIsDeniedAndClosed()
@Test func wrongProtocolVersionIsDenied()
@Test func firstFrameMustBeHelloOrPair()
@Test func pairWaitsForApprovalThenPairs()       // pair 正确 → 没有输出；approvePairing → [paired、welcome、snapshot]，进入 ready
@Test func rejectedPairingCloses()
@Test func badPairingCodeIsDenied()
@Test func answerForResolvedRequestRepliesResolved()  // 请求不存在 → result(ok: false, reason: .resolved)，submitAnswer 没被调用
@Test func answerWithForeignQuestionIsInvalid()       // question 类请求，answers 的键不在原题里 → .invalid，submitAnswer 没被调用
@Test func validAnswerIsSubmitted()
@Test func sayValidatesLengthAndMapsOutcome()
@Test func seenMarksSession()
@Test func broadcastOnlyWhenReady()
@Test func oversizedFrameCloses()
@Test func garbageWhileReadyIsIgnored()
```

- [ ] **Step 2: 运行，确认测试失败**

Run: `swift test --filter BridgeConnectionTests`
Expected: 编译失败。

- [ ] **Step 3: 实现 `BridgeConnection`**

- [ ] **Step 4: 运行，确认测试通过**

Run: `swift test`
Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/CritterCore/Bridge/BridgeConnection.swift Tests/CritterCoreTests/BridgeConnectionTests.swift
git commit -m "feat(core): bridge connection state machine"
```

---

### Task 9: Critter.app 里的 Bridge，以及开发用测试客户端

**Files:**
- Create: `Sources/CritterApp/Bridge/BridgeIdentity.swift`
- Create: `Sources/CritterApp/Bridge/BridgeServer.swift`
- Create: `Sources/CritterApp/Bridge/BridgeController.swift`
- Modify:
  - `Sources/CritterApp/AppDelegate.swift`：创建 Bridge、转发快照、补心跳字段、处理设置变化、新增调试入口
  - `Sources/CritterApp/PetController.swift`：新增 `func skinName(for sessionId: String) -> String`，有 `dealtSkins[id]` 就用它，否则用 `settings.skin`
  - `Sources/CritterApp/SessionMonitor.swift`：`MonitorEngine` 在识别到 Esc 中断、或者回收会话时，调用 `PendingStore(paths:).removeAll(sessionId:)`
  - `Sources/CritterApp/SettingsStore.swift`：新增 `bridgeEnabled`（Key 为 `"bridgeEnabled"`，默认 false，Change 为 `.bridge`），`applyDebugValue` 支持它
- Create: `Sources/critter-bridge-client/main.swift`
- Modify: `Package.swift`：新增 `.executableTarget(name: "critter-bridge-client", dependencies: ["CritterCore"])`

**Interfaces:**
- Consumes: Task 1–8 的全部 Core 类型。
- Produces（Task 10 和 Task 11 会用到）：
  - `BridgeIdentity.loadOrCreate(dir: URL) throws -> (identity: SecIdentity, fingerprint: String)`、`BridgeIdentity.reset(dir: URL)`。
    - 第一次运行时依次执行下面三条命令，生成三个文件，权限都是 0600，目录 0700：

      ```
      /usr/bin/openssl ecparam -name prime256v1 -genkey -noout -out key.pem
      /usr/bin/openssl req -new -x509 -key key.pem -out cert.pem -days 3650 -subj /CN=Critter
      /usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -out identity.p12 -passout pass:critter
      ```

    - 导入用 `SecPKCS12Import`。如果导入失败，第三条命令加上 `-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1` 重新生成。
    - `fingerprint` 是证书 DER 的 SHA-256，小写十六进制。
  - `final class BridgeServer`（在 bridge 队列上运行）：
    - 依次尝试 `BridgeProtocol.portRange` 里的端口。
    - `NWParameters(tls:)` 加上 `NWProtocolWebSocket.Options(autoReplyPing: true)`，并设置 `maximumMessageSize = maxFrameBytes`。
    - Bonjour 服务名是 `Host.current().localizedName ?? "Mac"`。
    - 来源地址不满足 `PrivateNetwork.isAllowed` 的，直接 `cancel()`。
    - 每个连接对应一个 `BridgeConnection`。
    - 10 分钟没有任何流量的连接会被关掉。
    - 对外的接口：`start(identity:) throws -> UInt16`、`stop()`、`broadcast(_:)`。
  - `final class BridgeController: BridgeServices`：
    - 队列是 `local.critter.pet.bridge`；
    - `var onPairRequest: (@MainActor (String, @escaping (Bool) -> Void) -> Void)?`：把"允许「设备名」连接？"这个请求交给界面处理；
    - `func setEnabled(_ on: Bool)`；
    - `func update(sessions: [PetSession], skins: [String: String], prefs: BridgePrefs)`：主线程调用，转到 bridge 队列执行；
    - `func beginPairing(autoApprove: Bool) -> PairingURI?`；
    - `func devices() -> [DeviceRecord]`、`func revoke(deviceId:)`、`func resetPairing()`：撤销所有设备，重新生成身份；
    - `var lastClientSeen: Int64?`：线程安全；
    - 用 `DirectoryWatcher` 监听 `pendingDir` 和 `statusDir`；
    - 快照的数据有变化时，最多等 250 ms 就合并推送一次；只有快照内容和上一次不同才推；
    - 每次重建快照前，先执行 `PendingStore.sweep(now:isAlive: ProcessTools.isAlive)`；
    - 分支缓存的键是 cwd 加上 `HEAD` 文件的修改时间；
    - 估算缓存的键是会话记录的路径加上文件大小和修改时间。只给没有状态栏上下文数据的会话估算，读取会话记录末尾的 64 KB。
    - `submitAnswer` 写入 `PendingStore.writeAnswer`；`say` 依次调用 `InboxStore.read` 和 `InboxSender.send`；`markSeen` 转到主线程，调用 `sessionMonitor.markSeen`；`skinManifest` 按 `skinSearchDirs` 的顺序查找，`clawd` 用 `SkinLoader.builtinJSON`。
  - AppDelegate 的改动：
    - `sessionMonitor.onSnapshot` 先调用 `petController.show`，再调用 `bridge.update(sessions:skins:prefs:)`；
    - `writeHeartbeat` 填上 `bridgeEnabled` 和 `lastClientSeen`；
    - 设置项 `.bridge` 变化时调用 `bridge.setEnabled`；
    - 设置项 `.skin`、`.randomSkins`、`.idleDim`、`.mergeThreshold` 变化时，用 `sessionMonitor.sessions` 重新调用一次 `bridge.update`，让 `prefs` 和形象分配及时推送出去；
    - 新增调试 URL `critter://debug-bridge-pair?out=<绝对路径>`，只在 `debugEnabled` 时有效：调用 `beginPairing(autoApprove: true)`，把 `{"uri":…}` 写进 out 指定的文件。
- `critter-bridge-client` 的子命令：
  - `pair <uri> [--state <path>]`：解析 URI，固定证书指纹连接，发 `pair`，收到 `paired` 后把 `{host, port, fingerprint, deviceId, token}` 存进 state 文件。state 默认是 `~/.critter/dev-client.json`。
  - `watch [--state] [--count N]`：发 `hello`，每收到一条消息就输出一行 JSON 到 stdout。
  - `answer <requestId> [--decision X] [--message M] [--answer "<问题原文>=<值>"]…`
  - `seen <sessionId>`
  - `say <sessionId> <text>`
  - `answer`、`seen`、`say` 都会打印 `result` 那一行，然后退出。
  - 实现用 `URLSessionWebSocketTask`。delegate 里比较服务端叶子证书 DER 的 SHA-256，一致时才信任。

- [ ] **Step 1: 实现上面三个 App 文件、对 AppDelegate / PetController / SessionMonitor / SettingsStore 的改动、测试客户端，以及 Package.swift 的改动**

- [ ] **Step 2: 编译并跑全部测试**

Run: `swift build && swift test`
Expected: 编译成功，全部测试通过。

- [ ] **Step 3: 手动打通**（用 `make app` 打包，再从 `dist/Critter.app` 启动）

```bash
defaults write local.critter.pet debugEnabled -bool true
open dist/Critter.app && open -g "critter://debug-set?bridgeEnabled=1"
open -g "critter://debug-bridge-pair?out=/tmp/critter-pair.json"
URI=$(python3 -c 'import json;print(json.load(open("/tmp/critter-pair.json"))["uri"])')
.build/debug/critter-bridge-client pair "$URI"
.build/debug/critter-bridge-client watch --count 1
```

Expected：
- `pair` 打印出 `paired`；
- `watch` 打印一行 `snapshot`，里面的 `sessions` 包含当前所有 Claude Code 会话，每个会话都有 `branch` 和 `context` 字段；
- `~/.critter/app.json` 里 `bridgeEnabled` 为 true，`lastClientSeen` 有值。

- [ ] **Step 4: 手动造一个待答请求来验证作答链路**

1. 用 `sleep 600 &` 拿到一个存活的 pid。
2. 按 `PendingRequest` 的格式往 `~/.critter/pending/` 写一个请求，`sessionId` 用当前某个会话的 id。
3. `watch` 应该在 1 秒内输出一份包含这个请求的快照。
4. 执行 `critter-bridge-client answer <id> --decision allow`，应该打印 `ok: true`，并且 `~/.critter/answers/<id>.json` 出现。
5. 删掉 pending 文件，再对同一个 id 执行 `answer`，应该打印 `reason: resolved`。

- [ ] **Step 5: 提交**

```bash
git add Package.swift Sources/CritterApp Sources/critter-bridge-client
git commit -m "feat(app): serve session snapshots and accept answers over the LAN"
```

---

### Task 10: 端到端脚本，以及 spec §13 待实测项的结论

**Files:**
- Create: `scripts/dev/e2e-phone.sh`
- Modify: `docs/superpowers/specs/2026-10-18-critter-android-design.md`：在 §13 写入结论
- Modify（只在实测发现格式不同时才改）: `Sources/CritterCore/AskDecision.swift`、`docs/critter-bridge-protocol.md`

**Interfaces:**
- Consumes: 已经 `make install` 的插件（必须包含 `ask`）、Task 9 的测试客户端和调试 URL。
- 脚本的前提条件：`make install` 已经执行过；Critter 正在运行；`debugEnabled` 已打开；`claude` 在 PATH 里。
- 脚本的做法：
  - 用 tmux 在临时目录启动 `claude --model haiku --permission-mode default`。启动前清掉 `CLAUDECODE` 和 `CLAUDE_CODE_*` 环境变量；遇到信任对话框时选"信任"。
  - 测试客户端 `watch` 在后台运行，输出写进一个 jsonl 文件。
  - 每个场景打印一行 `PASS <名字>` 或 `FAIL <名字>: <原因>`。
  - 结束时退出会话，删掉 `~/.claude/projects` 下这次的记录目录和产生的计划文件。

**场景**（每个场景的等待都要有上限，超时就判 FAIL）：
1. `permission-allow`：让 Claude 跑 `touch e2e-1.txt` → 等到出现一个 permission 类的请求 → 客户端回答 allow → 文件存在，请求从快照里消失。
2. `permission-deny-message`：回答 deny，理由是"换个文件名" → tmux 屏幕上出现这句话。
3. `question-single`：要求 Claude 用 AskUserQuestion 问一个选择题，选项是 One 和 Two → 回答 Two → 屏幕上出现 `→ Two`。
4. `question-multi`：要求 Claude 出一道多选题（`multiSelect: true`），选项是 A、B、C → 回答 `A, B` → 记下屏幕上的显示和 Claude 的复述。**这是 spec §13 第 1 条。** 如果 Claude 没能拿到两个选项，就试另外两种写法：用 `,` 连接、用 JSON 数组字符串。在 `AskDecision` 和协议文档里定下能用的那种格式，再补一个单元测试 `questionMultiSelectFormat`。
5. `question-free-text`：回答 `Mango` → Claude 复述 Mango。
6. `plan-revise-then-approve`：用 BTab 切到计划模式 → 回答 revise，附修改意见 → 计划重新提交 → 回答 approve → 退出计划模式。
7. `terminal-first`：等到出现请求后，在 tmux 里按 Enter 允许 → 工具结束后 2 秒内，请求从快照里消失，`ask` 进程也退出了（用 `pgrep -f "critter-hook ask"` 检查）。
8. `escape-clears`：等到出现请求后按 Esc → 2 秒内请求消失。
9. `subagent-permission`：要求 Claude 派一个子代理去执行 `touch e2e-sub.txt` → 记下请求的 `sessionId` 是不是父会话的 id。**这是 spec §13 第 4 条。**
10. `say`：会话空闲时，用客户端发"只回复 PINEAPPLE" → 屏幕上出现 PINEAPPLE。

不能自动测的几项，在 spec §13 里写成手工检查步骤：
- 第 2 条：在本方案里，电脑上作答后请求会被撤销，hook 不会再输出，所以这条基本不会触发。只要写明这个结论。
- 第 3 条：VS Code 或 Antigravity 里的会话。
- 第 5 条：状态栏没有原命令时，终端的样子是否和没有状态栏一样。

- [ ] **Step 1: 写脚本**
- [ ] **Step 2: 运行**

Run: `make install && scripts/dev/e2e-phone.sh`
Expected：
- 10 行结果里，场景 1、2、3、5、6、7、8、10 都是 `PASS`；
- 场景 4 和 9 打印出观察到的结果；
- 如果场景 4 定下了新的格式，补上单元测试，并确认 `swift test` 全部通过。

- [ ] **Step 3: 把结论写进 spec §13 的对应条目**（每条一两句，写明实测日期和 Claude Code 版本）
- [ ] **Step 4: 提交**

```bash
git add scripts/dev/e2e-phone.sh docs Sources/CritterCore Tests
git commit -m "test(dev): end-to-end phone answering against a real Claude Code session"
```

---

### Task 11: 设置窗口的"手机"一节，以及 README

**Files:**
- Create: `Sources/CritterApp/Bridge/PhoneSettingsSection.swift`
- Modify:
  - `Sources/CritterApp/SettingsWindow.swift`：在 `SettingsView` 里加入这一节
  - `Sources/CritterApp/AppDelegate.swift`：把 `bridge.onPairRequest` 接到设置窗口
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 9 的 `BridgeController` 和 Task 2 的 `StatusLineInstaller`。
- 这一节的内容（spec §6.6）：
  - **开关"允许手机连接"**：绑定 `settings.bridgeEnabled`。
  - **"添加手机…"**：打开一个弹层，里面有：
    - 用 `CIFilter.qrCodeGenerator` 生成的二维码，内容是 `PairingURI.string`；
    - 8 位码，按 4+4 显示；
    - 剩余有效时间；过期后变成"重新生成"按钮；
    - 有手机请求配对时，显示一行"「设备名」请求连接"和"拒绝""允许"两个按钮，`onPairRequest` 的回调就在这里触发。
    - **不能用模态的 `NSAlert`**：桌面 spec §9 规定宠物不能因为模态窗口而拖不动。
  - **已配对设备列表**：显示名字和最后在线时间（几分钟前），每台都可以撤销。
  - **"状态栏数据"一行**：
    - 状态是"已接入"、"未接入"或"已被改成其它类型"，由 `StatusLineInstaller.status` 读 `~/.claude/settings.json` 得出；
    - 按钮是"接入"或"撤销"，在后台队列上执行，规则和 CLI 一样（先备份）。
  - **"重置配对"**：先在行内确认，然后调用 `resetPairing()`。
- **README** 新增"手机连接（Mac 端）"一节，内容有：
  - 怎么打开和配对；
  - 状态栏是怎么包装的、怎么撤销；
  - 能在手机上作答的范围，以及"电脑和手机谁先答算谁的"；
  - 安全边界（spec §10 的原话）；
  - 已知限制：在电脑上允许了一个耗时较长的命令后，手机上的卡片要等命令跑完才会消失；
  - 新增的 `ask` hook，以及插件版本号已经升到 0.3.0。

- [ ] **Step 1: 实现设置这一节和配对弹层，并接好回调**
- [ ] **Step 2: 编译**

Run: `swift build && make app`
Expected: 成功。

- [ ] **Step 3: 手动验证**

打开 `dist/Critter.app` → 设置 → 手机：
1. 打开开关，点"添加手机"，二维码和 8 位码都出现。
2. 用 `critter-bridge-client pair <弹层里显示的 URI>` 配对，弹层上出现请求那一行。点"允许"后客户端打印 `paired`；点"拒绝"时打印 `denied`。
3. 设备列表里出现 "critter-bridge-client"，撤销之后再执行 `watch`，打印 `denied badToken`。
4. "状态栏数据"显示"已接入"（前提是已经 `make install`）。点"撤销"后 `~/.claude/settings.json` 里恢复成原来的命令，再点"接入"又包装回去。

- [ ] **Step 4: 更新 README，提交**

```bash
git add Sources/CritterApp README.md
git commit -m "feat(app): phone pairing and status line settings"
```
