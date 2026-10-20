# Codex phone adaptation and desktop source repair

User scope: improve mobile telemetry and real message/question/approval controls, and fix desktop Codex sessions labelled “其他”.

## Findings and implementation

- The installed Critter binary predated Codex support; a bare-UUID Codex state file also lacked entrypoint/PID. Source resolution now recognises validated legacy transcripts and aliases, migration preserves Seen/dismissed state, and current host ancestry wins over the client that originally created a rollout. ChatGPT-hosted Codex is recognised explicitly.
- CodexTelemetry preserves the reported model, effective context window, latest response token usage and duration-matched quota windows. Codex values are per session and do not enter Claude's account quota.
- Optional bridge capabilities gate messaging, answering and stopping. Codex without a confirmed control connection stays read-only. Android supports generic Codex sources, current-thread messaging, keyguard-protected stop, per-session quota, desktop-only prompts, and unsupported rejection-reason suppression.
- CodexIPCClient connects only to the same user's existing `$CODEX_HOME/ipc/ipc.sock`. It does not start another app-server, resume a historical thread or change Codex config. The current Desktop/VS Code coordinator's private, versioned protocol is adapted from the installed official extension (26.1007.21434).
- Framing is UInt32LE length plus UTF-8 JSON. The current owner must affirm support; stream v11 snapshots and revision-checked Immer patches supply live requests. Each action targets that owner. Start inherits thread settings; steer includes the owner's required restoreMessage; interrupt binds expectedTurnId.
- Native question IDs and original RPC ID types survive conversion. One-off approvals never become session-wide grants. Secret/verification/unknown prompts remain on desktop. Approval IDs bind canonical params and a fresh local snapshot generation.
- Timeouts or lost confirmations after writes are unconfirmed, with no automatic message retry. Unknown/changed owners withdraw capabilities. Indefinite Codex prompts omit a synthetic maximum Android notification timeout.

## Review and validation

- Independent IPC review found missing active-message restore context, false definite results after disconnect, reused approval identifiers, and the actual `latestTokenUsageInfo.last` shape. Each was reproduced in focused tests and fixed.
- Local Unix-socket fixtures exercise current-owner message and approval forwarding, stale-generation rejection and no retry after uncertain delivery.
- A read-only live probe connected to the current Desktop conversation, confirmed the Desktop source and complete model/token/window telemetry. No actual conversation messages or approvals were sent during testing.
- Android core: 310 tests, zero failures/errors. Android app: 108 tests, zero failures/errors. Signed release APK 1.1.0 (code 2) produced and verified with apksigner.
- Full Swift regression initially exposed a timing issue in a test-only Process.terminate(); the fixture now uses SIGKILL on its own temporary child to exercise crash cleanup, with bounded asynchronous liveness checks.
- Final Swift result and local app deployment are recorded below after completion.

## Compatibility limits

Standalone CLI sessions remain readable; remote actions require an existing coordinator owner. The private coordinator interface may change with Codex upgrades; incompatible versions disable actions. Pure file-open/close changes without writes can delay rollout discovery. No Android device was connected through ADB during this update, so on-device acceptance requires installing the generated APK.

## Follow-up: progress bubbles and command activity (2026-10-21)

- User observed input prompts during command execution and asked to see public commentary in the pet bubble. Legacy hooks continue recreating bare-UUID records; Catalog now deterministically prefers the canonical confirmed Codex record even before disk cleanup. Catalog focused suite: 19 passed.
- SessionRecord keeps optional public progress. Commentary from message/agent_message phase=commentary survives reasoning and tool outputs. Tool animation remains independent. New turn/abort clears it; real waiting, errors and terminal state retain priority. Internal reasoning content is never read into the bubble.
- Active calls and structured shell session/cell results keep bash animation during background commands. Correlated completion removes the background marker. Only exact input tool names enter waiting.
- Independent review reproduced two edges: late commentary reviving an aborted turn and stdout containing a fake running-session marker. Closed-turn/time checks and strict runner-header parsing fixed both, with RED→GREEN regression tests.
- Target desktop patch version is 0.3.1. Android 1.1.0 already displays the shared detail text and requires no parser-side app change.

## Final result (2026-10-21)

- Full Swift suite: 541 tests passed. Android core/app suites: 310 + 108 tests passed; signed Android 1.1.0 APK retained at `dist/Critter-Android-1.1.0.apk`.
- Critter 0.3.1 was installed over the old application and restarted. Installed binary hash matches the tested release build; installed bundle signature verification passed. Pairing/settings and Codex/Claude configuration were preserved.
- Actual live record verified after upgrade: entrypoint `codex-desktop`, state `running`, activity `bash`, and detail exactly the latest public progress commentary. No actual conversation message/approval was sent during verification.
- `git diff --check` and installer shell syntax checks passed.

## Follow-up: directory and source labels (2026-10-21)

- Speech-bubble headers show only the working-directory basename, with the full path on hover. Reading cwd directly avoids catalog-generated source suffixes on duplicate session names.
- Source remains below the pet: Codex keeps `Codex · Desktop / VS Code / 终端`; known Claude Code sources use the short `cc · Desktop / VS Code / 终端` form.
- `swift test --no-parallel`: all 541 tests passed. Two parallel full-suite attempts hit the existing two-second child-exit deadline in `codexDiscoveryRequiresALiveProcessHoldingTheRollout`; the same test passed in isolation. This fixture timing issue remains separate from the view-only changes.
- Release build and signature check passed. Critter 0.3.2 (build 5) replaced the running local app with a rollback backup and unchanged pairing/settings. The live accessibility tree confirmed `clawd` in the bubble header, `Codex · Desktop` below it, and `cc · 终端` below the Claude Code pet.
