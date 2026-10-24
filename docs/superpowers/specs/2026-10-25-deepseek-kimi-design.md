# DeepSeek Harness and Kimi Code support — design

**Status:** approved in conversation 2026-10-25 ("和 Claude Code 一样，但也要能批准操作"; "手机上就行"; "没有问题").

## Intent

The user now has two more coding agents installed next to Claude Code and Codex: **DeepSeek Harness** (`/Applications/DeepSeek Harness.app`, `com.deepseek.dsh`, 0.2.1-rc.3) and **Kimi Code** (`/Applications/Kimi Code.app`, `com.kimi.code.desktop`, 1.1.2). Both are Electron desktop apps. Critter should treat their sessions the way it treats Claude Code sessions, so that one row of pets watches every agent on the Mac, and the phone can approve what they are waiting on.

## Goals

1. Every live DeepSeek Harness and Kimi Code session gets its own pet, with the same states as Claude Code: idle, running (with the `think` / `laptop` / `read` / `bash` / `juggle` activity where the tool is known), waiting, done (bubble = first sentence of the last assistant message), error. It joins when the session becomes active and leaves when the session or the app goes away.
2. Labels: `Kimi · Desktop` (and `Kimi · 终端` for the Kimi CLI client if it ever shows up), `DeepSeek · Desktop`. Clicking a pet activates that app.
3. The phone (iOS and Android) lists these sessions and can **approve or reject a pending permission request**, and **answer a question** the agent asked, wherever the agent's own interface supports it. Whichever side answers first — the phone or the agent's own window — wins; the other side's prompt is withdrawn or ignored.
4. Sounds, push notifications, merge/flock behaviour, dismiss ("关闭"), and seen-state work for them exactly as for Claude Code, because they flow through the same `SessionRecord` / catalog / bridge pipeline.

## Non-goals

- Sending a message to the session ("发一句") or stopping a turn from the phone. Capabilities report `canSay = false`, `canInterrupt = false` with a reason.
- Jumping to a specific conversation. Neither app has a per-session deep link (`kimi-code://open?root=…` always starts a *new* chat; `dsh://open` only focuses the main window). Clicking activates the app.
- Showing a Kimi or DeepSeek session's history from before it became active while Critter watched (no historical scan, same rule as Codex).
- Context/usage/model telemetry on the phone for these agents (may come later).
- DeepSeek CLI profiles (`dsh --profile headless/acp/sdk`) and DeepSeek subagent child sessions as separate pets.

## Anti-goals

- **Never block the agent.** A Critter that is not running, a phone that is not connected, or any failure must leave both apps behaving exactly as without Critter: their own approval prompt appears and works.
- **Never auto-approve.** An approval is only ever the phone user's explicit decision on that one request.
- Never print, copy or log Kimi's `config.toml` secrets, `server.token`, `~/.dsh/.credentials.yaml`, or any credentials.
- Never break existing Claude Code / Codex behaviour or old phones (unknown sources decode as `other`).

## Constraints

- macOS 14+, Swift 6, **no third-party dependencies** in the Swift package (existing rule). The DeepSeek plugin is plain JavaScript with no npm dependencies.
- Both agents' storage formats and local APIs are internal and unversioned; adapters must tolerate unknown fields/events and partial data, and the README must say an update may need adapter changes (as it does for Codex).
- Existing schema-1 `SessionRecord` files stay readable; new fields are optional.

## What the investigation established (verified from the app bundles)

### Kimi Code

- Runs a local server. Each running server writes `~/.kimi-code/server/instances/<serverId>.json` `{server_id, pid, host, port, started_at, heartbeat_at, host_version}`; heartbeat every 15 s; deleted on clean shutdown. Desktop binds `127.0.0.1` on a random port. `KIMI_CODE_HOME` overrides `~/.kimi-code`.
- Auth: `Authorization: Bearer <~/.kimi-code/server.token>` (0600). Unauthenticated: `/openapi.json`, `/asyncapi.json`, `/api/v1/healthz`.
- WebSocket `ws://127.0.0.1:<port>/api/v1/ws`: `server_hello`; must answer `ping{nonce}` with `pong{nonce}`; every connection gets `event.session.*` for all sessions (notably `event.session.work_changed {busy, main_turn_active, pending_interaction: none|approval|question, last_turn_reason}`); `subscribe {session_ids, cursors}` adds per-session `turn.started`, `tool.call.started {toolCallId, name, args}`, `tool.result`, `event.approval.requested {approval_id, tool_name, action, tool_input_display, …}`, `event.approval.resolved`, `event.question.requested/answered/dismissed`, `turn.ended {reason: completed|cancelled|failed|blocked, error}`, `error`. `resync_required` → rebuild from REST.
- REST: `GET /api/v1/sessions` (with `busy`, `pending_interaction`, `last_turn_reason`, `title`, workspace root), `GET /sessions/{id}/messages?role=assistant`, `GET /sessions/{id}/approvals`, and routes to resolve approvals / answer questions (exact paths and bodies to be read from the live `/openapi.json` in the spike).
- Kimi also has `[[hooks]]` in `config.toml`, but PermissionRequest hooks cannot answer and the file holds API keys; not used.
- Tool names: `Read Write Edit Bash Glob Grep Agent AgentSwarm AskUserQuestion WebSearch FetchURL …`.

### DeepSeek Harness

- A cordis plugin host. User layers: `~/.dsh/cordis.patch.yml` (all profiles) and `~/.dsh/profiles/desktop/cordis.patch.yml` (desktop). Plugins run **in the host process, outside the Seatbelt sandbox** that confines hook commands (hooks cannot write `~/.critter`, so the hooks bridge is not used).
- A plugin can listen to `session/event (session, event)` for every durable event, `agent/status`, `agent/created`, `agent/disposed`, `agent/error`, and can join the `approval/request` and `user-questions/request` waterfalls.
- Durable events: `turn/start`, `turn/end {reason.kind: completed|blocked|aborted|error|max-tokens…}`, `assistant/message {content:[text|reasoning|tool-call]}`, `tool/call {callId, name, arguments}`, `tool/result`, `approval/asked`, `approval/decided`, …
- Approval: the service passes `req` (with `toolName`, `callId`, `reason`, `signal`) down the waterfall; a listener returns `allowed-once` | `rejected` or calls `next()`. The desktop UI answerer (`dsh-client-ui-approval`) shows its panel and **withdraws it when `request.signal` aborts**. So a Critter listener in front can call `next({...req, signal: ours})`, race that against the phone, and abort `ours` when the phone wins.
- Tool names: `bash read edit write str_replace_editor glob grep subagent subagent_fork ask_user_question web_fetch web_search …`.
- No session-level deep link; `com.deepseek.dsh` is activated.

## The design

### Shared: sources, catalog, bridge, phones

- `SessionSource` gains `kimiDesktop = "kimi_desktop"`, `kimiTerminal = "kimi_terminal"`, `deepseekDesktop = "deepseek_desktop"`, built from entrypoints `kimi-desktop`, `kimi-cli`, `deepseek-desktop`. Labels `Kimi · Desktop`, `Kimi · 终端`, `DeepSeek · Desktop`. An `isKimi` / `isDeepSeek` / "is third-party agent" helper keeps Claude-only logic (registry, SDK exclusion, `cc ·` prefix, transcript interruption detection) away from them, the way `isCodex` does today.
- Session ids are namespaced: `kimi-<id>`, `deepseek-<id>` (DeepSeek ids already look like `session-<uuid>`; the record id is `deepseek-session-<uuid>`).
- Jump: `kimiDesktop`/`kimiTerminal` → activate `com.kimi.code.desktop` (terminal: no-op if no GUI ancestor); `deepseekDesktop` → activate `com.deepseek.dsh`.
- Bridge capabilities for these sessions: `canSay = false`, `canInterrupt = false`, `canAnswer = true` when their answer channel is live, otherwise false with a `readOnlyReason` such as `尚未连接 Kimi Code` / `请在电脑上的 DeepSeek Harness 中处理`.
- Phones: iOS and Android add the three source values with the same labels (phone wording: `Kimi · Desktop`, `Kimi · 终端`, `DeepSeek · Desktop`) and the laptop / terminal icons. No other phone UI changes; wishes go to the phone backlog.

### Kimi: an app-side client of Kimi's local server (like `CodexIPCClient`)

- `KimiDiscovery` reads the instances directory, keeps entries whose pid is alive and whose heartbeat is recent, and reads the token. Watches the directory so start/stop of Kimi is noticed without polling.
- `KimiClient` (one per live server) connects the WebSocket, handles ping/pong, lists sessions over REST, subscribes, and reduces events per session into `SessionRecord`s written through `StateStore` (owner pid = server pid, so the existing reaper removes them when Kimi exits). It runs whenever Critter runs — not only when the phone bridge is on — because it is the source of the desktop pets too.
- Which sessions are pets: a session becomes a pet when it is busy or has a pending interaction at connect time, or when it starts a turn while Critter watches; it stays (done/idle) until it is archived/deleted, the server goes away, or the user dismisses it. Mapping:
  - `turn.started` → running/`think`; `tool.call.started` → running with activity from the tool name and a summary from its args; `tool.result` → running/`think`.
  - `event.approval.requested` → waiting with a permission summary; `event.question.requested` → waiting `BubbleText.askQuestion`; resolved/answered/dismissed → running.
  - `turn.ended completed` → done with the first sentence of the last assistant message (fetched over REST); `failed` → error with the message; `cancelled`/`blocked` → idle.
  - `work_changed` reconciles state if an event was missed.
- Phone answers: pending approvals/questions are exposed as remote pending requests (`requestId` prefixed `kimi-`) beside the hook-written ones, and `submitAnswer` routes `kimi-` ids to `KimiClient`, which calls Kimi's resolve/answer REST route. If Kimi's own window answered first, the request disappears via `event.approval.resolved` and the phone's late answer reports already-answered.
- Settings: the phone section shows a Kimi channel status line next to the Codex one.

### DeepSeek: a small plugin inside DeepSeek Harness that feeds `critter-hook`

- Lives in the repo as `integrations/deepseek/` (`package.json` marked as a dsh bundle, `cordis.patch.yml`, `lib/index.js`), plain ESM, no dependencies. `make install` installs/updates it into DeepSeek's desktop profile when DeepSeek Harness is present (exact install command determined in the spike); `make uninstall` removes it. DeepSeek must be restarted once to load it.
- The plugin translates DeepSeek events into **Claude-Code-shaped hook payloads** and runs `~/.critter/bin/critter-hook event` for each (spawned directly, no shell, stdin = JSON, env `CRITTER_ENTRYPOINT=deepseek-desktop`), so the existing reducer, pending-request store, bridge and push work unchanged:
  - first activity / `agent/created` → `SessionStart`; `turn/start` → `UserPromptSubmit`; `tool/call` → `PreToolUse` with the tool name mapped to its Claude equivalent (`bash`→`Bash`, `read`→`Read`, `edit`/`str_replace_editor`→`Edit`, `write`→`Write`, `glob`→`Glob`, `grep`→`Grep`, `web_fetch`→`WebFetch`, `web_search`→`WebSearch`, `subagent*`→`Agent`, `ask_user_question`→`AskUserQuestion`, others pass through) and arguments mapped to Claude's keys where the meaning matches (`command`, `file_path`, `pattern`, …); `tool/result` → `PostToolUse`; `approval/asked` → `PermissionRequest`; `approval/decided` rejected → `PermissionDenied`, allowed → `PostToolUse`-like running; `turn/end completed` → `Stop` with `last_assistant_message` = the turn's last assistant text; `error`/`max-tokens` → `StopFailure`; `aborted` → idle; `agent/disposed` / session closed → `SessionEnd`.
  - `critter-hook` learns `CRITTER_ENTRYPOINT`: when set, the record's entrypoint is that value and its owner pid is the hook's parent (the DeepSeek host process), instead of searching for a `claude` ancestor.
- Approvals: the plugin prepends an `approval/request` listener. It always calls `next()` with a request carrying its own `AbortController` signal (chained to the original), so DeepSeek's panel appears as usual, and in parallel runs `critter-hook ask` with a `PermissionRequest` payload. `AskCommand` accepts `deepseek-desktop` as an entrypoint it may wait for (the race makes that safe). First answer wins: phone allow → `allowed-once`, phone deny → `rejected`, and our signal aborts to withdraw the panel; panel answer first → kill the `ask` child and retract its pending request. If `critter-hook` is missing or `ask` prints nothing, only `next()` decides.
- Questions: same pattern on `user-questions/request` when the phone's answer can be mapped to DeepSeek's answer shape; otherwise the question stays computer-only (pending kind not published, capability reason says so).
- Robustness: every spawn has a timeout, errors are swallowed and logged only to the DeepSeek host log at debug level, and the plugin does nothing if `~/.critter/bin/critter-hook` does not exist.

### Documentation

README: a "DeepSeek Harness 接入" and "Kimi Code 接入" section (what is shown, what needs a restart, approval behaviour, no per-session jump, custom `KIMI_CODE_HOME`, adapter may need updates after app updates); the phone protocol doc lists the new sources.

## Verification

- Unit tests: source parsing/labels; Kimi event → record reduction and session admission; Kimi pending/answer routing; `critter-hook` with `CRITTER_ENTRYPOINT`; `AskCommand` gate; plugin translator and approval race (`node --test`, no dependencies).
- Android `:core:test :app:testDebugUnitTest` and iOS tests for the new sources.
- Live checks on this Mac: Kimi Code with a real session (running, tool activity, approval answered from a simulated phone answer, done bubble, quit → pet leaves); DeepSeek Harness with the plugin installed (same list). Results recorded in the plan, including anything not verified.

## Decisions after the builder check (my calls)

- **DeepSeek approvals reach Critter only when a person would be asked.** DeepSeek's permission presets and rules decide *before* `approval.request()` is called, and the only other `approval/request` listeners are the UI relay (`dsh-api-remotes`) and the ACP answerer (another profile). So a request in the waterfall is already headed for the user, like Claude Code's `PermissionRequest`.
- **A DeepSeek session joins on its first `turn/start` (or `approval/asked`), not on `agent/created`.** The spike showed `agent/created` (source `resume`) fires at app launch for the last-open session; using it would make every restored session a pet.

## Spike results (2026-10-25, on this Mac)

### Kimi Code 1.1.2 (server `host_version` 2.3.0)

- `instances/<id>.json` appeared within ~1 s of launch: `{"server_id","pid","host":"127.0.0.1","port":63812,"started_at","heartbeat_at","host_version":"2.3.0"}`; the pid is the Electron main process (`/Applications/Kimi Code.app/Contents/MacOS/Kimi Code`, ppid 1).
- `/openapi.json` and `/asyncapi.json` **require** the bearer token (only `/api/v1/healthz` is open).
- WebSocket auth via subprotocol `kimi-code.bearer.<token>` works from Node's `WebSocket`. Frames are `{type, seq, epoch, session_id, timestamp, payload}`; `server_hello.payload = {ws_connection_id, protocol_version: 2, heartbeat_ms: 10000, …}`; `subscribe` is acked with `{accepted, not_found, resync_required, cursors}`. Global frames (`event.session.*`, `event.workspace.*`) arrive unsubscribed.
- Observed sequence for a turn: `prompt.submitted` → `turn.started {turnId, prompt, origin}` → `event.session.work_changed {busy:true, main_turn_active:true, pending_interaction:"none"}` → `turn.step.started` → … → `turn.ended {reason:"failed", error:{code, message}}` → `error` → `work_changed {busy:false, last_turn_reason:"failed"}` → `prompt.completed`.
- **The user's Kimi subscription currently returns 403 for every model** ("Your current subscription does not have access to Kimi Code right now"), so no tool call, approval or completed turn could be produced live. Those shapes come from `asyncapi.json` and the bundle source:
  - `tool.call.started {agentId, turnId, toolCallId, name, args, description, display}`; `display.kind` ∈ `command{command,cwd}`, `file_io{operation: read|write|edit|glob|grep, path}`, `diff{path}`, `search{query}`, `url_fetch{url}`, `agent_call{agent_name,prompt}`, `generic{summary}`, …
  - `event.approval.requested {approval_id, session_id, agent_id, turn_id, tool_call_id, tool_name, action, tool_input_display (same display union), created_at, expires_at}`; `event.approval.resolved {approval_id, decision, scope, feedback, selected_label}`.
  - `event.question.requested {question_id, questions:[{id:"q_<i>", question, header?, body?, options:[{id:"opt_<i>_<j>", label, description?}], multi_select?, allow_other:true}], turn_id?, tool_call_id?}`; `event.question.answered|dismissed {question_id}`.
  - `turn.ended.reason` ∈ `completed|cancelled|failed|blocked`.
- REST (from the live `openapi.json`): `POST /api/v1/sessions/{sid}/approvals/{approval_id}` `{decision: "approved"|"rejected"|"cancelled"}`; `GET …/approvals?status=pending`; `POST /api/v1/sessions/{sid}/questions/{question_id}` `{answers: {"q_0": {kind:"single", option_id} | {kind:"multi", option_ids} | {kind:"other", text} | {kind:"skipped"}}}` (`…/questions/{id}:dismiss` with an empty body dismisses); `GET /api/v1/sessions?busy=false&include_archive=false&exclude_empty=false&archived_only=false&page_size=100` (all four booleans are required query params); `GET /sessions/{sid}/messages?role=assistant&page_size=1`. Responses are `{code, msg, data, request_id}`; `code != 0` is a failure even with HTTP 200.
- Session objects: `{id:"session_<uuid>", workspace_id, title, busy, main_turn_active, pending_interaction, last_turn_reason?, metadata:{cwd}, …}`.
- The spike sessions and workspace it created were deleted again.

### DeepSeek Harness 0.2.1-rc.3

- **Install:** `"/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh" plugin --profile desktop add link:<absolute dir>` adds the dependency *and* appends the package name to `dsh.profile.bundles` in `~/.dsh/profiles/desktop/package.json`; `… remove <name>` undoes both. A restart of DeepSeek Harness loads it. Bundle = `package.json` with `"dsh": {"bundle": {"patch": "./cordis.patch.yml"}}`, `cordis.patch.yml` = `- insert: [{id: critter, name: <package name>}]`, `lib/index.js` exporting `name` and `apply(ctx)`.
- The plugin runs in the **host process** (`…/MacOS/DeepSeek Harness --expose-internals …dsh-desktop-host…`), a child of the app's main process. A `critter-hook` spawned by the plugin therefore has the host as its parent; the host exits when the app quits.
- Events seen live: `agent/created {source:"resume"}` at launch; `agent/status {status: running|idle}`; `session/event` with `turn/start {turn}`, `step/start`, `assistant/message {message:{content:[{type:"reasoning"},{type:"text",text}|{type:"tool-call",id,name,arguments(JSON string)}]}}`, `tool/call {callId, name:"bash", arguments:"{\"command\":…}"}`, `tool/result`, `approval/asked {id, toolName, callId, reason}`, `approval/decided {id, outcome}`, `step/end`, `turn/end {turn, reason:{kind:"completed"}}`, plus noise (`system/message`, `user/message`, `request/*`, `session-log-*`, `session/title*`, `agent/inbox/spliced`, `job/*`). `session.header` has `id`, `cwd`, `delegationDepth` (0 for top-level sessions).
- `approval/request` listener registered with `ctx.on(…, fn, true)` (prepend) runs first and receives `req = {agent, toolName, callId, reason, displayReason:{en, zh}, signal}`.
- **Withdrawing DeepSeek's own panel:** cordis' waterfall `next()` takes no arguments — later listeners get the *same* `req` object — and the gateway that relays the request to the UI reads `req.signal` when it forwards. Setting `req.signal = ours` (an `AbortController` chained to the original signal; the object is not frozen) before `next()` makes `ours.abort()` withdraw the panel: the UI promise rejected and the sidebar's "待审批" badge disappeared. Without the swap the panel stayed "待审批" after the request was settled.
- Phone-wins path verified end to end: returning `"allowed-once"` from the listener produced `approval/decided allowed-once` and the escalated command ran.
- Not verified live: the panel answering first (needs a click); `user-questions/request`. The probe plugin was removed and the profile restored.

## Left to the builder

- File/type names and how `KimiClient` shares code with `CodexIPCClient`.
- Kimi's tool/approval/question handling is built from schema and source, not a live run (subscription); tests use fixtures shaped from the schema above.
