# DeepSeek Harness and Kimi Code support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show every live DeepSeek Harness and Kimi Code session as a pet with Claude-Code-level states, and let the phone approve/reject their permission requests and answer their questions.

**Architecture:** Shared: three new `SessionSource` values flow through the existing record → catalog → bridge → phone pipeline. Kimi: an app-side client of Kimi's local server (WebSocket events + REST answers) writes `SessionRecord`s and exposes remote pending requests, like `CodexIPCClient`. DeepSeek: a dependency-free JS plugin inside DeepSeek's host translates its events into Claude-Code-shaped hook payloads for `critter-hook event`/`ask`, racing the phone against DeepSeek's own approval panel.

**Tech Stack:** Swift 6 / SwiftPM (no third-party deps), Foundation `URLSessionWebSocketTask`; plain ESM JavaScript run by DeepSeek's bundled Node 24 (`node --test` for tests); Kotlin (Android), SwiftUI (iOS).

**Spec:** `docs/superpowers/specs/2026-10-25-deepseek-kimi-design.md` (read its "Spike results" section — event shapes, REST routes and the DeepSeek signal-swap are verified facts there).

## Global Constraints

- macOS 14+, Swift 6, no third-party dependencies in `Package.swift`; the DeepSeek plugin has no npm dependencies.
- Never block the agent: any Critter failure leaves Kimi / DeepSeek behaving exactly as without Critter (their own prompt appears and works).
- Never auto-approve: an approval is only the phone user's explicit decision on that one request.
- Never print, log or copy `~/.kimi-code/server.token`, `config.toml` secrets, `~/.dsh/.credentials.yaml`.
- Existing Claude Code / Codex behaviour and schema-1 `SessionRecord` files stay unchanged; old phones decode unknown sources as `other`.
- Ids: Kimi record id `kimi-<kimi session id>` (e.g. `kimi-session_9c3b…`), DeepSeek record id `deepseek-<dsh session id>` (e.g. `deepseek-session-2e9f…`); Kimi pending request id `kimi-<approval_id|question_id>`.
- Entrypoints / sources: `kimi-desktop` → `.kimiDesktop` (`"kimi_desktop"`, label `Kimi · Desktop`); `kimi-cli` → `.kimiTerminal` (`"kimi_terminal"`, `Kimi · 终端`); `deepseek-desktop` → `.deepseekDesktop` (`"deepseek_desktop"`, `DeepSeek · Desktop`). Bundle ids: `com.kimi.code.desktop`, `com.deepseek.dsh`.
- Read-only reasons (exact copy): Kimi not connected `尚未连接 Kimi Code`; no "say" for these agents `Kimi Code 会话暂不支持从手机发消息` / `DeepSeek Harness 会话暂不支持从手机发消息`.
- Work on `main` (user preference); commit after each task with the session's attribution lines.

## Review Focus

1. **Kimi not running / restarted / port changed** — no pets, no errors; when Kimi starts or restarts (new instances file, new port), the client reconnects within a few seconds and stale `kimi-` records of the old pid disappear. Test: `KimiClientTests.testServerRestartReplacesOwnerAndDropsOldRecords`.
2. **Phone answers a request the agent's own window already answered** — Kimi: REST returns non-zero `code` → `AnswerOutcome.alreadyAnswered`, request removed; DeepSeek: the `ask` child was killed, pending file swept. Tests: `KimiClientTests.testAnswerAfterResolvedReportsAlreadyAnswered`, `approval.test.js › ui answers first kills ask and returns ui outcome`.
3. **Critter not running or phone not connected while DeepSeek asks** — `critter-hook ask` prints nothing immediately; the plugin's result is exactly DeepSeek's own panel answer, with no delay. Test: `approval.test.js › silent ask defers to ui`.
4. **Many historical Kimi sessions / DeepSeek sessions restored at launch** — none become pets until they start a turn or ask for approval. Tests: `KimiReducerTests.testIdleSessionsAtConnectAreNotAdmitted`, `translate.test.js › agent created alone emits nothing`.
5. **DeepSeek subagent child sessions and noise events** (`delegationDepth > 0`, `system/message`, `job/*` …) — never produce hook calls. Test: `translate.test.js › child sessions and noise are ignored`.

---

## File map

| File | Responsibility |
|---|---|
| `Sources/CritterKit/SessionSource.swift` (modify) | new cases, entrypoint parsing, labels, `isKimi`, `isDeepSeek`, `isAgentApp` |
| `Sources/CritterKit/Push/NotificationText.swift` (modify) | phone/push wording for new sources |
| `Sources/CritterCore/JumpPlan.swift` (modify) | activate Kimi / DeepSeek bundles |
| `Sources/CritterCore/Bridge/BridgeSnapshot.swift` (modify) | default capabilities for new sources |
| `Sources/CritterCore/StateReducer.swift` (modify) | `Interrupted` event → idle |
| `Sources/CritterCore/HookCommand.swift`, `AskCommand.swift` (modify) | `CRITTER_ENTRYPOINT` |
| `Sources/CritterCore/KimiProtocol.swift` (create) | instance discovery, frame/REST decoding, pure session reducer, phone-request mapping |
| `Sources/CritterCore/KimiClient.swift` (create) | connection lifecycle, record writes, pending/answers/capabilities |
| `Sources/CritterApp/AppDelegate.swift`, `Bridge/BridgeController*.swift`, `Bridge/PhoneSettingsSection.swift` (modify) | wiring |
| `integrations/deepseek/{package.json,cordis.patch.yml,lib/translate.js,lib/index.js,test/*.test.js}` (create) | DeepSeek plugin |
| `scripts/install.sh`, `scripts/uninstall.sh`, `Makefile` (modify) | install/remove plugin, `make test` runs node tests |
| `ios/Critter/Look/PlaceRow.swift`, Android `Messages.kt`, `SessionUi.kt` (modify) | phone labels/icons |
| `README.md`, `docs/critter-bridge-protocol.md` (modify) | docs |

---

### Task 1: New session sources across the Mac side

**Files:**
- Modify: `Sources/CritterKit/SessionSource.swift`, `Sources/CritterKit/Push/NotificationText.swift:84-90`, `Sources/CritterCore/JumpPlan.swift:47-78`, `Sources/CritterCore/Bridge/BridgeSnapshot.swift:44-61`, `Sources/CritterApp/TagView.swift` (no change needed if default branch shows `label`; verify)
- Test: `Tests/CritterCoreTests/CatalogTests.swift` (or a new `SessionSourceTests.swift`), `JumpPlanTests.swift`, `SnapshotBuilderTests.swift`, `Tests/CritterKitTests/NotificationTextTests.swift`

**Interfaces:**
- Produces: `SessionSource.kimiDesktop / .kimiTerminal / .deepseekDesktop`; `var isKimi: Bool`, `var isDeepSeek: Bool`, `var isAgentApp: Bool` (true for Kimi and DeepSeek — "not Claude, not Codex, has no Claude registry"); `JumpPlanner.kimiDesktop = "com.kimi.code.desktop"`, `JumpPlanner.deepseekDesktop = "com.deepseek.dsh"`.

- [ ] **Step 1: Write failing tests**
  - `SessionSource(entrypoint: "kimi-desktop") == .kimiDesktop`, `"kimi-cli"` → `.kimiTerminal`, `"deepseek-desktop"` → `.deepseekDesktop`; raw values `"kimi_desktop"`, `"kimi_terminal"`, `"deepseek_desktop"`; labels `Kimi · Desktop`, `Kimi · 终端`, `DeepSeek · Desktop`; `isCodex == false`, `isAgentApp == true` for all three; `SessionSource.isExcluded(entrypoint:)` unchanged.
  - `SessionCatalog.build` with a record `{sessionId: "kimi-session_x", entrypoint: "kimi-desktop"}` and an unrelated registry entry of the same id never takes the registry's name/pid/source (same guard as Codex).
  - `JumpPlanner.plan(guiAncestor: nil, source: .kimiDesktop, …) == .activateBundle("com.kimi.code.desktop")`; `.deepseekDesktop` → `.activateBundle("com.deepseek.dsh")`; `.kimiTerminal` without GUI ancestor → `.none`.
  - Snapshot: a `.deepseekDesktop` session with no entry in `inputs.capabilities` gets `BridgeCapabilities(canSay: false, canAnswer: true, canInterrupt: false, readOnlyReason: "DeepSeek Harness 会话暂不支持从手机发消息")`; a `.kimiDesktop` session without an entry gets `BridgeCapabilities(readOnlyReason: "尚未连接 Kimi Code")`. Model/context/limits stay nil for both.
  - `NotificationText.source(.kimiDesktop) == "Kimi · Desktop"` etc.
- [ ] **Step 2: Run** `swift test --filter 'CatalogTests|JumpPlanTests|SnapshotBuilderTests|NotificationTextTests'` — expect compile failures (unknown cases).
- [ ] **Step 3: Implement.** In `SessionCatalog.build` treat `recordSource.isAgentApp` exactly like `isCodex` (registry never consulted, SDK exclusion skipped). Exhaustive switches elsewhere (`TagView`, `NotificationText`, `FlockLayout`, iOS shared code compiled from CritterKit) must compile — `grep -rn "case .codexDesktop" Sources ios` and add the new cases (desktop icon/laptop for Desktop, terminal for `kimiTerminal`).
- [ ] **Step 4: Run** `swift test` — all pass.
- [ ] **Step 5: Commit** `feat: Kimi Code and DeepSeek Harness session sources`.

### Task 2: `critter-hook` learns `CRITTER_ENTRYPOINT`; reducer learns `Interrupted`

**Files:**
- Modify: `Sources/CritterCore/HookCommand.swift:181-200` (runEvent locate/entrypoint), `Sources/CritterCore/AskCommand.swift:61-70`, `Sources/CritterCore/StateReducer.swift`
- Test: `Tests/CritterCoreTests/HookCommandTests.swift`, `AskCommandTests.swift`, `ReducerTests.swift`

**Interfaces:**
- Produces: env `CRITTER_ENTRYPOINT` (only value accepted now: `deepseek-desktop`; constant `HookCommand.agentAppEntrypoints: Set<String> = ["deepseek-desktop"]`). Hook event `Interrupted` → idle.

- [ ] **Step 1: Failing tests**
  - `HookCommandTests.testAgentAppEntrypointOwnsHookParent`: `run(arguments: ["event"], stdin: {"session_id":"deepseek-session-1","cwd":"/tmp/p","hook_event_name":"UserPromptSubmit","prompt":"hi"}, environment: ["CRITTER_ENTRYPOINT": "deepseek-desktop"], hookParentPid: 4242, processes: fake where 4242 is alive with start time 100 and is NOT a claude executable)` writes a record with `entrypoint == "deepseek-desktop"`, `claudePid == 4242`, `claudeStartTime == 100`, `state == .running`.
  - Unknown `CRITTER_ENTRYPOINT` value (`"evil"`) is ignored (existing Claude behaviour: no pid when no claude ancestor, entrypoint nil).
  - `AskCommandTests.testDeepSeekEntrypointWaits`: with `CRITTER_ENTRYPOINT=deepseek-desktop` (and no `CLAUDE_CODE_ENTRYPOINT`), an answered request yields the same stdout as for `cli`. Without either env → silent (unchanged).
  - `ReducerTests.testAgentAppQuestionBubble`: a `PreToolUse` `AskUserQuestion` for a record whose entrypoint is `deepseek-desktop` → detail `DeepSeek 在问你问题`; Claude sessions keep `Claude 在问你问题`. Implement as `BubbleText.askQuestion(entrypoint: String?) -> String` (`kimi-*` → `Kimi 在问你问题`, `deepseek-*` → `DeepSeek 在问你问题`, else the existing `BubbleText.askQuestion`); the reducer passes `entrypoint ?? previous?.entrypoint`. Task 5 uses the Kimi wording.
  - `ReducerTests.testInterruptedGoesIdle`: previous running record + `hook_event_name: "Interrupted"` → `.write` with `state == .idle`, `detail == nil`, `activity == nil`; `PendingResolution.apply(event: "Interrupted", …)` removes the session's pending requests (add `"Interrupted"` to the `removeAll` case).
- [ ] **Step 2: Run** `swift test --filter 'HookCommandTests|AskCommandTests|ReducerTests|PendingResolutionTests'` — new tests fail.
- [ ] **Step 3: Implement.** In `runEvent`: if `environment["CRITTER_ENTRYPOINT"]` ∈ `agentAppEntrypoints`, use `LocatedClaude(pid: hookParentPid, startTime: processes.startTime(of: hookParentPid), entry: nil)` and that entrypoint, skipping `ClaudeProcessLocator`; skip the transcript-progress read and the messaging-socket inbox write. `AskCommand.run`: accept `CLAUDE_CODE_ENTRYPOINT == "cli"` **or** `CRITTER_ENTRYPOINT ∈ HookCommand.agentAppEntrypoints`.
- [ ] **Step 4: Run** `swift test` — pass.
- [ ] **Step 5: Commit** `feat(hook): CRITTER_ENTRYPOINT for agent apps; Interrupted event`.

### Task 3: DeepSeek plugin — pure translator

**Files:**
- Create: `integrations/deepseek/package.json`, `integrations/deepseek/cordis.patch.yml`, `integrations/deepseek/lib/translate.js`, `integrations/deepseek/test/translate.test.js`

**Interfaces:**
- Produces (ESM, `lib/translate.js`):
  - `mapTool(name: string, args: object) -> {toolName: string, toolInput: object}`
  - `class SessionTranslator { constructor(headerId: string, cwd: string); feed(event: {type, data}) -> HookPayload[] }` where `HookPayload` is a Claude-Code hook stdin object (`session_id`, `cwd`, `hook_event_name`, …); `session_id = "deepseek-" + headerId`.
  - `toolInputFor(callId: string) -> {toolName, toolInput} | undefined` (method on `SessionTranslator`, used by Task 4's approval listener).
  - `askAnswerToDeepSeek(kind: "permission"|"question", hookStdout: string, questions?: object[]) -> "allowed-once"|"rejected"|{answers:[{id, selected:string[], custom?:string}]}|null`
- `package.json`: `{"name":"critter-deepseek","version":"1.0.0","type":"module","main":"lib/index.js","exports":{".":"./lib/index.js","./cordis.patch.yml":"./cordis.patch.yml","./package.json":"./package.json"},"dsh":{"bundle":{"patch":"./cordis.patch.yml"}},"peerDependencies":{"@deepseek-ai/cordis":"~4.0.5"},"description":"Critter desktop pet: reports DeepSeek Harness sessions and forwards approvals to the phone."}`. `cordis.patch.yml`: `- insert:\n    - id: critter\n      name: critter-deepseek`.

- [ ] **Step 1: Failing tests** (`node --test integrations/deepseek/test`), using event objects shaped exactly like the spike log in the spec:
  - `agent created alone emits nothing` — translator fed nothing / only `system/message`, `user/message`, `request/header` → `[]`.
  - `turn start joins` — first `turn/start` → `[SessionStart{source:"startup"}, UserPromptSubmit{prompt:<last user/message text with source.kind "user", else "">}]`; a second turn → only `UserPromptSubmit`.
  - `tool call maps to Claude names` — `tool/call {callId:"c1", name:"bash", arguments:"{\"command\":\"ls\",\"description\":\"x\"}"}` → `PreToolUse{tool_name:"Bash", tool_input:{command:"ls", description:"x"}}`; `read {path:"a.txt"}` → `Read {file_path:"a.txt", path:"a.txt"}`; `edit`/`str_replace_editor` → `Edit`, `write` → `Write`, `glob` → `Glob`, `grep` → `Grep`, `web_fetch` → `WebFetch`, `web_search` → `WebSearch`, `subagent`/`subagent_fork` → `Agent`, `ask_user_question` → `AskUserQuestion` with `questions` converted to Claude shape `{question, header, multiSelect, options:[{label, description}]}`, `exit_plan_mode` → `ExitPlanMode`, unknown `todo_write` → `todo_write` unchanged. Unparseable `arguments` → `tool_input: {}`.
  - `tool result reuses the call input` — `tool/result {message:{toolCallId:"c1"}}` → `PostToolUse` with the **identical** `tool_name`/`tool_input` as the `PreToolUse` for `c1` (matchKey must match).
  - `approval asked` → `PermissionRequest{tool_name, tool_input}` from the call map (`toolName` fallback mapped via `mapTool(toolName, {})`); joins the session first if not joined.
  - `approval decided` — `rejected`/`cancelled`/`unavailable` → `PermissionDenied` with the call's tool name/input; `allowed-once` → `[]`.
  - `turn end` — `completed` → `Stop{last_assistant_message: <last text block of the last assistant/message of this turn>}` (reasoning blocks ignored; none → omit field); `error` → `StopFailure{error_type:"error", error_message: reason.error.message}`; `max-tokens` → `StopFailure{error_message:"max-tokens"}`; `aborted`/`blocked` → `Interrupted`.
  - `child sessions and noise are ignored` — translator constructed for a header with `delegationDepth > 0` is never created (export `isTopLevel(header) -> boolean`, false when `delegationDepth > 0`).
  - `askAnswerToDeepSeek` — `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` → `"allowed-once"`; `behavior:"deny"` → `"rejected"`; `""` or invalid JSON → `null`; question: `updatedInput.answers {"Pick one?":"B"}` with questions `[{id:"q1",question:"Pick one?",options:[{label:"A"},{label:"B"}]}]` → `{answers:[{id:"q1",selected:["B"]}]}`; multi-select `"A, B"` → `selected:["A","B"]`; text matching no label → `{id, selected:[], custom:"text"}`.
- [ ] **Step 2: Run** `node --test integrations/deepseek/test` — fails (module missing).
- [ ] **Step 3: Implement `lib/translate.js`.** Keep per-session state: `joined`, `callMap: Map<callId,{toolName,toolInput}>`, `turnLastText`, `lastUserText`. Generic arg rule: copy all parsed args; if `path` is present and `file_path` absent, add `file_path = path`.
- [ ] **Step 4: Run** `node --test integrations/deepseek/test` — pass.
- [ ] **Step 5: Commit** `feat(deepseek): event translator for the DeepSeek Harness plugin`.

### Task 4: DeepSeek plugin — host wiring, approval/question race, install

**Files:**
- Create: `integrations/deepseek/lib/index.js`, `integrations/deepseek/test/approval.test.js`
- Modify: `scripts/install.sh`, `scripts/uninstall.sh`, `Makefile` (`test:` also runs `node --test integrations/deepseek/test` when `node` exists)

**Interfaces:**
- Consumes: Task 3 exports; Task 2's `CRITTER_ENTRYPOINT=deepseek-desktop`.
- Produces: `export const name = "critter-deepseek"; export function apply(ctx, config = {})` (config: `hookPath` default `$HOME/.critter/bin/critter-hook`); exported for tests: `createRunner({spawn, hookPath, env}) -> {event(payload) -> Promise<void>, ask(payload, signal) -> Promise<string>}` and `raceApproval({req, next, ask, payload, map}) -> Promise<outcome>`.

- [ ] **Step 1: Failing tests** (`approval.test.js`, fake `spawn` and fake `next`):
  - `phone wins aborts our signal` — ask resolves stdout allow after 10 ms, `next` never settles until its signal aborts: result `"allowed-once"`; `req.signal` was replaced before `next()` was called and is aborted afterwards; original signal untouched.
  - `ui answers first kills ask and returns ui outcome` — `next` resolves `"rejected"` at 5 ms, ask pending: result `"rejected"`, the ask child got `kill()`.
  - `silent ask defers to ui` — ask resolves `""` immediately: result is whatever `next` resolves, no abort.
  - `original abort propagates` — aborting the original `req.signal` aborts ours and kills ask; result is `next`'s rejection/outcome (no phone decision invented).
  - `events are serialized per session` — two `event()` calls for the same session spawn the second only after the first child exits; each child gets stdin = JSON + `\n`, env includes `CRITTER_ENTRYPOINT=deepseek-desktop`, argv `["event"]`; a child running > 5 s is killed.
  - `missing hook is a no-op` — `hookPath` that does not exist: `event()` resolves without spawning, `raceApproval` returns `next()`'s result.
- [ ] **Step 2: Run** `node --test integrations/deepseek/test` — fails.
- [ ] **Step 3: Implement `lib/index.js`.** In `apply(ctx)`: one `SessionTranslator` per top-level session id; `ctx.on("session/event", (session, event) => …)` feeds it and calls `runner.event` per payload; `ctx.on("agent/disposed", ({agent}) => …)` emits `SessionEnd` for a joined session and drops it; `ctx.on("approval/request", fn, true)` and `ctx.on("user-questions/request", fn, true)` call `raceApproval`. **Signal swap (verified in spike):** `const ours = new AbortController(); req.signal?.addEventListener("abort", () => ours.abort(req.signal.reason), {once: true}); req.signal = ours.signal;` then `next()` with no arguments. Ask payload: `{session_id, cwd, hook_event_name: "PermissionRequest", tool_name, tool_input}` (questions: `tool_name: "AskUserQuestion"`, `tool_input: {questions: <Claude shape>}`). Map ask stdout with `askAnswerToDeepSeek`; `null` → keep waiting for `next()`. Spawn with `child_process.spawn(hookPath, [arg], {stdio: ["pipe","pipe","ignore"], env: {...process.env, CRITTER_ENTRYPOINT: "deepseek-desktop"}})`; never throw out of a listener (wrap in try/catch, fall back to `next()`).
- [ ] **Step 4: Install scripts.**
  - `install.sh`, after critter-hook is installed: if `/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh` exists: copy `integrations/deepseek` (without `test/`) to `$CRITTER_HOME/deepseek/` (replace contents), then if `~/.dsh/profiles/desktop/package.json` does not already list `critter-deepseek` in `dependencies`, run `"$DSH" plugin --profile desktop add "link:$CRITTER_HOME/deepseek"`; print `DeepSeek Harness 需要重启一次才会加载 Critter 插件。`. Failure prints a warning and continues. Otherwise print `未检测到 DeepSeek Harness，已跳过。`.
  - `uninstall.sh`, **before** removing `$CRITTER_HOME`: if the profile lists `critter-deepseek`, run `"$DSH" plugin --profile desktop remove critter-deepseek || true`.
  - Final line of install: `Critter 已安装，支持 Claude Code、Codex、Kimi Code 和 DeepSeek Harness。启动：open ~/Applications/Critter.app`.
- [ ] **Step 5: Run** `node --test integrations/deepseek/test`, `bash -n scripts/install.sh scripts/uninstall.sh` — pass.
- [ ] **Step 6: Commit** `feat(deepseek): host plugin with phone approval race; install and uninstall it`.

### Task 5: Kimi protocol — discovery, decoding, pure reducer, phone requests

**Files:**
- Create: `Sources/CritterCore/KimiProtocol.swift`
- Test: `Tests/CritterCoreTests/KimiProtocolTests.swift` (fixtures inline, shaped from the spec's Kimi spike section)

**Interfaces:**
- Produces:
  - `struct KimiInstance: Equatable, Sendable { serverId: String; pid: Int32; host: String; port: Int; startedAt: Int64; heartbeatAt: Int64 }` + `enum KimiDiscovery { static func instances(in dir: URL) -> [KimiInstance]; static func live(_ all: [KimiInstance], now: Int64, isAlive: (Int32) -> Bool) -> KimiInstance? }` (live = pid alive and `now - heartbeatAt <= 60_000`; newest `startedAt` wins).
  - `CritterPaths.kimiHome` (`$KIMI_CODE_HOME` else `~/.kimi-code`), `kimiInstancesDir`, `kimiTokenFile` — add to `CritterPaths.swift`.
  - `struct KimiFrame { type: String; sessionId: String?; payload: JSONValue }` with `static func decode(_ data: Data) -> KimiFrame?` (top-level `type`, `session_id`, `payload`).
  - `struct KimiSessionState: Equatable, Sendable { id: String; cwd: String; title: String?; state: PetState; detail: String?; activity: WorkActivity?; admitted: Bool; lastEvent: String }`
  - `enum KimiReducer { static func reduce(_ s: KimiSessionState, frame: KimiFrame) -> KimiSessionState; static func initial(session: JSONValue) -> KimiSessionState? }` (from a REST/`event.session.created` session object: `id`, `metadata.cwd`, `title`, `busy`, `pending_interaction`).
  - `func record(for s: KimiSessionState, owner: KimiInstance, ownerStartTime: Int64?, entrypoint: String, previous: SessionRecord?, now: Int64) -> SessionRecord` (id `kimi-<id>`, schema 1).
  - `struct KimiPhoneRequest: Equatable, Sendable { pending: PendingRequest; kimiSessionId: String; kimiId: String; isQuestion: Bool; questions: [JSONValue] }` with `init?(frame: KimiFrame, now: Int64, ownerPid: Int32)` for `event.approval.requested` / `event.question.requested`, and `func body(for answer: AnswerPayload) -> (path: String, json: [String: Any])?`.
- [ ] **Step 1: Failing tests**
  - Discovery: two instance files (one dead pid, one live) → `live` returns the live one; stale heartbeat (61 s) → nil; malformed file skipped.
  - `testIdleSessionsAtConnectAreNotAdmitted`: `initial` of `{busy:false, pending_interaction:"none"}` → `admitted == false`; `busy:true` → admitted, `.running`, activity `.think`.
  - Reducer: `turn.started` → admitted, running/think, detail `思考中` (use `BubbleText.thinking`); `tool.call.started {name:"Bash", args:{command:"npm test"}}` → running, `activity == .bash`, detail `ToolSummary.activity(toolName:"Bash", input:…)`; name `FetchURL` → `.read`, `AgentSwarm`/`Agent` → `.juggle`, `Edit {path:"a.swift"}` → `.laptop` with `file_path` mapped from `path` for the summary; `tool.result` → running/think; `event.approval.requested {tool_name:"Bash", tool_input_display:{kind:"command", command:"rm -rf x"}}` → waiting with `ToolSummary.permission(toolName:"Bash", input:{command:"rm -rf x"})`; `event.question.requested` → waiting `Kimi 在问你问题` (`BubbleText.askQuestion(entrypoint: "kimi-desktop")`); `event.approval.resolved` / `event.question.answered|dismissed` → running/think; `turn.ended reason:"completed"` → `.done` detail `BubbleText.done` (Task 6 replaces it with the message); `failed` with `error.message "403 …"` → `.error` detail `BubbleText.errorPrefix + ToolSummary.truncate(message, max: 50)`; `cancelled`/`blocked` → `.idle`, detail nil.
  - `event.session.work_changed` is only a correction for missed events (it arrives for every session, subscribed or not). Table, given the current state → result: `busy:true` & state ∈ {idle, done, error} or not admitted → admitted, running/think; `pending_interaction:"approval"` & state ≠ waiting → waiting, detail `需要你确认` (prefix `BubbleText.confirmPrefix` without colon content: use `"需要你确认"`); `pending_interaction:"question"` & state ≠ waiting → waiting `Kimi 在问你问题`; `busy:false` & `pending_interaction:"none"` & state ∈ {running, waiting} → by `last_turn_reason`: `completed` → done (`BubbleText.done`), `failed` → error (`出错了：` + nothing more known → `"出错了"`), `cancelled`/absent → idle; every other combination leaves the state unchanged. One test per row.
  - Unknown frame types leave state unchanged.
  - `KimiPhoneRequest`: approval frame → `pending.requestId == "kimi-approval_1"`, `kind == .permission`, `toolName == "Bash"`, `input == {command: "rm -rf x"}`, `sessionId == "kimi-session_1"`, `hookPid == ownerPid`, `expiresAt == .max`; `body(for: decision "allow")` → path `/api/v1/sessions/session_1/approvals/approval_1`, json `{decision: "approved"}`; deny with message `"no"` → `{decision: "rejected", feedback: "no"}`.
  - Question frame `{question_id:"qq", questions:[{id:"q_0", question:"Which?", header:"H", options:[{id:"opt_0_0",label:"A"},{id:"opt_0_1",label:"B"}], multi_select:false}]}` → `kind == .question`, `toolName == "AskUserQuestion"`, `input == {questions:[{question:"Which?", header:"H", multiSelect:false, options:[{label:"A"},{label:"B"}]}]}`; `body(answers {"Which?":"B"})` → path `/api/v1/sessions/session_1/questions/qq`, json `{answers: {"q_0": {kind:"single", option_id:"opt_0_1"}}}`; multi `"A, B"` → `{kind:"multi", option_ids:[…]}`; free text → `{kind:"other", text}`; answers that fail `AskDecision.validate` → nil.
- [ ] **Step 2: Run** `swift test --filter KimiProtocolTests` — fails.
- [ ] **Step 3: Implement** in `KimiProtocol.swift` (pure, no I/O except `KimiDiscovery.instances` reading files).
- [ ] **Step 4: Run** `swift test --filter KimiProtocolTests` — pass.
- [ ] **Step 5: Commit** `feat(kimi): protocol decoding, session reducer and phone requests`.

### Task 6: Kimi client — connection, records, answers

**Files:**
- Create: `Sources/CritterCore/KimiClient.swift`
- Test: `Tests/CritterCoreTests/KimiClientTests.swift`

**Interfaces:**
- Consumes: Task 5 types; `StateStore`, `CritterPaths`, `ProcessTools`, `DirectoryWatcher` (Watchers.swift).
- Produces:
  - `protocol KimiTransport: AnyObject, Sendable { func connect(port: Int, token: String, onFrame: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void); func send(_ data: Data); func close(); func request(port: Int, token: String, method: String, path: String, body: Data?, completion: @escaping @Sendable (Data?) -> Void) }` and `final class URLSessionKimiTransport: KimiTransport` (WebSocket `ws://127.0.0.1:<port>/api/v1/ws` with header `Authorization: Bearer <token>`; REST same header, 5 s timeout).
  - `final class KimiClient: @unchecked Sendable { init(paths: CritterPaths, transport: KimiTransport = URLSessionKimiTransport(), now: @escaping @Sendable () -> Int64 = …, isAlive: @escaping @Sendable (Int32) -> Bool = ProcessTools.isAlive, onChange: @escaping @Sendable () -> Void = {}); func start(); func stop(); func refresh(); var requests: [KimiPhoneRequest] { get }; func answer(_ payload: AnswerPayload, requestID: String) -> AnswerOutcome; var capabilities: [String: BridgeCapabilities] { get }; var statusText: String { get } }` — all state on one serial queue (pattern of `CodexIPCClient`).
- Behaviour to pin in tests (fake transport replays frames; temp `CritterPaths`):
  - `testConnectsToLiveInstance`: writes a fake instances file + token file; `start()` → transport `connect(port:token:)` with those values; after `server_hello`, client sends `{"type":"client_hello","id":…,"payload":{"client_id":"critter"}}` and requests `GET /api/v1/sessions?busy=false&include_archive=false&exclude_empty=true&archived_only=false&page_size=100`.
  - `testPingPong`: frame `{"type":"ping","payload":{"nonce":"n1"}}` → sends `{"type":"pong","payload":{"nonce":"n1"}}`.
  - `testWorkChangedBusyAdmitsAndSubscribes`: global `event.session.work_changed {busy:true}` for `session_1` (with a cached session list giving cwd) → record `kimi-session_1` written via `StateStore` (`state .running`, `entrypoint "kimi-desktop"`, `claudePid` = instance pid) and a `subscribe` frame for `["session_1"]` is sent; on subscribe, `GET …/approvals?status=pending` and `…/questions?status=pending` are requested and returned items become `requests`.
  - `testCompletedTurnFetchesLastAssistantMessage`: `turn.ended completed` → `GET /api/v1/sessions/session_1/messages?role=assistant&page_size=20`; response items → pick the item with the greatest `created_at` if present, else the last; detail = `ToolSummary.firstSentence(<joined text parts>, max: 50)`; record `.done`.
  - `testAnswerApprovalPostsDecision`: pending approval + `answer(AnswerPayload(decision:"allow"), requestID:"kimi-approval_1")` → `POST /api/v1/sessions/session_1/approvals/approval_1` body `{"decision":"approved"}`, response `{"code":0}` → `.accepted`, request removed.
  - `testAnswerAfterResolvedReportsAlreadyAnswered`: response `{"code":40404,…}` → `.alreadyAnswered`; unknown id → `.alreadyAnswered`; transport error → `.failed`.
  - `testResolvedEventRemovesRequest`: `event.approval.resolved` removes the request and calls `onChange`.
  - `testServerRestartReplacesOwnerAndDropsOldRecords`: records owned by old pid exist; instances file now names a new pid/port → reconnect to new port; `kimi-` records whose `claudePid` is not the live instance pid are deleted.
  - `testNoInstanceMeansNoRecordsAndReason`: no instances → `statusText == "尚未连接 Kimi Code"`, capabilities for known kimi sessions carry that reason; `kimi-` records are deleted.
  - `testArchivedOrDeletedSessionRemovesRecord`: `event.session.archived` / `event.session.deleted` for `session_1` → record deleted.
  - `resync_required` → re-list sessions and re-fetch pending for that session.
  - Capabilities when connected: `BridgeCapabilities(canSay: false, canAnswer: true, canInterrupt: false, readOnlyReason: "Kimi Code 会话暂不支持从手机发消息")`.
- Entrypoint: `kimi-desktop` when `ProcessTools.executablePath(of: pid)` contains `/Kimi Code.app/`, else `kimi-cli`.
- Reconnect: watch `kimiInstancesDir` (create-on-demand watcher semantics like `DirectoryWatcher`) and retry with backoff 1 s → max 30 s while no live instance; `refresh()` re-evaluates immediately.
- [ ] **Step 1: Write the failing tests above.**
- [ ] **Step 2: Run** `swift test --filter KimiClientTests` — fails.
- [ ] **Step 3: Implement `KimiClient.swift`.**
- [ ] **Step 4: Run** `swift test` — all pass.
- [ ] **Step 5: Commit** `feat(kimi): local server client writes pets and answers phone requests`.

### Task 7: Wire Kimi into the app and the bridge

**Files:**
- Modify: `Sources/CritterApp/AppDelegate.swift:55-145`, `Sources/CritterApp/Bridge/BridgeController.swift:39-60,99,390-420`, `Sources/CritterApp/Bridge/BridgeController+Services.swift:28-45`, `Sources/CritterApp/Bridge/PhoneSettingsSection.swift` (status line next to "Codex 手机操作")
- Test: `Tests/CritterCoreTests/SnapshotAssemblerTests.swift` (pending merge + capabilities precedence)

**Interfaces:**
- Consumes: `KimiClient` (Task 6), new sources (Task 1).
- Produces: `BridgeController.init(…, kimi: KimiClient)`; snapshot pending = hook pending + Codex remote + `kimi.requests.map(\.pending)`; capabilities = `codexControl.capabilities.merging(kimi.capabilities)`; `submitAnswer` routes ids with prefix `kimi-` to `kimi.answer`; `pendingRequest(_:)` also looks in `kimi.requests`; `say` for `kimi-`/`deepseek-` sessions returns `.unavailable`.
- [ ] **Step 1: Failing test** — `SnapshotAssemblerTests.testKimiRemotePendingAndCapabilities`: assembling with a kimi session + one remote pending (`kimi-approval_1`) → snapshot contains that pending and the session's capabilities from the provided dict.
- [ ] **Step 2: Run** `swift test --filter SnapshotAssemblerTests` — fails if assembly needs changes; otherwise it documents the contract (keep it).
- [ ] **Step 3: Implement wiring.** `AppDelegate` creates `KimiClient(paths:onChange:)` (onChange → `bridge.refreshSnapshot()` equivalent used by Codex's onChange, and `monitor.refresh()`), starts it in `applicationDidFinishLaunching` regardless of the phone setting, stops it in `applicationWillTerminate`. Settings row text: `Kimi Code：\(kimi.statusText)`.
- [ ] **Step 4: Build and run** `swift build && swift test` — pass.
- [ ] **Step 5: Commit** `feat(kimi): run the Kimi client with the app; route phone answers`.

### Task 8: Phones — new sources

**Files:**
- Modify: `ios/Critter/Look/PlaceRow.swift:33-38` (and any other exhaustive `SessionSource` switch under `ios/`), `android/core/src/main/kotlin/local/critter/core/protocol/Messages.kt:55`, `android/app/src/main/kotlin/local/critter/phone/ui/SessionUi.kt:30-47`
- Test: `android/core/src/test/kotlin/local/critter/core/protocol/MessagesTest.kt`, `android/app/src/test/kotlin/local/critter/phone/CodexSessionUiTest.kt` (add cases) and the iOS test target that covers `SessionText`/`PlaceRow` if present.

- [ ] **Step 1: Failing tests** — Android: decoding `"kimi_desktop"`, `"kimi_terminal"`, `"deepseek_desktop"` yields the new enum values; `sourceLabel` gives `Kimi · Desktop`, `Kimi · 终端`, `DeepSeek · Desktop`; `sourceIcon` → `laptop`, `term`, `laptop`; `supportsMessages` for such a session with `capabilities = BridgeCapabilities(canSay=false, canAnswer=true)` is false and `supportsAnswers` true. iOS: same labels/icons via the shared `NotificationText.source` (Task 1) and `PlaceRow.icon`.
- [ ] **Step 2: Run** `cd android && ./gradlew :core:test :app:testDebugUnitTest` (proxy per memory if Gradle needs network) — fails.
- [ ] **Step 3: Implement** enum cases (Kotlin names `kimi_desktop`, `kimi_terminal`, `deepseek_desktop`), labels, icons.
- [ ] **Step 4: Run** Android tests and `make ios-test` (or `xcodebuild … test` as in the Makefile) — pass.
- [ ] **Step 5: Commit** `feat(phone): Kimi Code and DeepSeek Harness sources on iOS and Android`.

### Task 9: Docs and live verification

**Files:**
- Modify: `README.md` (title line, requirements, new sections "Kimi Code 接入" and "DeepSeek Harness 接入"), `docs/critter-bridge-protocol.md` (source values), this plan (results)

- [ ] **Step 1: README.** Contents per spec "Documentation": what is shown; Kimi needs nothing installed and no restart, custom `KIMI_CODE_HOME` must reach Critter's process; DeepSeek needs `make install` + one restart of DeepSeek Harness; approvals: whichever of phone / app window answers first wins; clicking activates the app (no per-session jump); adapters may need updates after app updates; Kimi's subscription 403 shows as an error pet.
- [ ] **Step 2: Full test run.** `swift test`, `node --test integrations/deepseek/test`, `bash -n scripts/*.sh`, Android tests, iOS tests, `git diff --check`.
- [ ] **Step 3: Install and live check.** `make install`; restart DeepSeek Harness; then in DeepSeek (drive a prompt in the default workspace) verify: pet appears on first turn with label `DeepSeek · Desktop`, `bash` shows the bash animation, an escalation approval shows "等你确认" and a pending request in `~/.critter/pending/` while the phone bridge is on (simulate the phone by writing an answer with `PendingStore.writeAnswer`-equivalent: `~/.critter/answers/<requestId>.json` `{"decision":"allow"}`), DeepSeek's panel withdraws, done bubble shows the reply; quitting DeepSeek removes the pet. Kimi: launch Kimi Code, confirm the settings status line says connected and that a turn (even the 403 one) produces an error pet; quitting Kimi removes it. Record every result, and what could not be verified, under "Verification" below.
- [ ] **Step 4: Commit** `docs: Kimi Code and DeepSeek Harness support; verification notes`.

## Verification

Run 2026-10-25 on the development Mac (macOS 27.0.1, DeepSeek Harness 0.2.1-rc.3, Kimi Code 1.1.2 / server 2.3.0).

- `swift test`: all pass except the two pre-existing flaky real-process tests in `CodexTests` (`codexDiscoveryRequiresALiveProcessHoldingTheRollout`, `codexDiscoveryUsesCurrentDesktopHostInsteadOfCreationSource`), which fail the same way on the baseline 16023f8.
- `node --test "integrations/deepseek/test/*.test.js"`: 32/32. `bash -n scripts/*.sh` clean. Android `:core:test :app:testDebugUnitTest`: 421 passed. `make ios-sim`: BUILD SUCCEEDED.
- `make install`: installed Critter.app and critter-hook, copied the plugin to `~/.critter/deepseek` and registered it in `~/.dsh/profiles/desktop` (`dsh.profile.bundles` gained `critter-deepseek`).
- **DeepSeek live** (prompt submitted to the default-workspace session through a temporary trigger-only probe plugin, removed afterwards): first turn → record `deepseek-session-2e9f…` with `entrypoint deepseek-desktop`, owner pid = DeepSeek host; `bash` → `PreToolUse`/`PostToolUse`; sandbox escalation → `PermissionRequest` → state `waiting`, bubble `需要你确认：Bash(mkdir -p ~/critter-live-chec…`, a `permission` pending request with toolName `Bash` (bridge on, iPhone push reachable); writing `{"decision":"allow"}` as the phone answer → DeepSeek logged `approval/decided allowed-once`, the command ran, `Stop` → `done` with the reply's first sentence; pending and answer files cleaned up; quitting DeepSeek removed the record.
- **Kimi live**: Critter connected to the running Kimi server (pid 75662). A session created over REST and prompted once failed with Kimi's 403 → record `kimi-session_fb88…` `state error`, detail `出错了：403 Your current subscription does not have acces…`, `entrypoint kimi-desktop`, owner pid 75662; deleting the session removed the record. The test session and workspace were deleted.
- **Not verified live:** DeepSeek's own panel answering first, and DeepSeek questions (no way to click its UI unattended); the panel-withdraw on a phone win was verified with screenshots in the spike, but this run's screenshots were black (display asleep); every Kimi tool call, approval, question and completed turn (the account's subscription returns 403 for all models) — these are covered by schema-shaped unit tests only; the phone UI itself (answers were simulated by writing the answer file the bridge writes).
- Plan correction: Task 6 listed sessions with `busy=false` only; Kimi filters on it, so the client lists `busy=false` and `busy=true` and unions them (fix b160988).
