# Codex support implementation plan

**Goal:** Show local Codex Desktop, CLI and VS Code sessions alongside Claude Code pets.

**Architecture:** Discover rollout files held open by live `codex` processes using macOS process APIs. Observe the Codex sessions directory with FSEvents, incrementally reduce complete JSONL records into the existing session schema, and reuse the catalog, process cleanup, animations and phone snapshots. Codex configuration and transcripts remain read-only.

**Constraints:** macOS 14+, Swift 6, no third-party dependencies. Keep existing Claude integration and schema compatibility. Exclude exec, internal and subagent sessions. Do not poll or scan historical session directories. Unknown events and incomplete writes must be harmless.

**Sources:** [Codex notification limits](https://developers.openai.com/codex/config-advanced/#notifications), [rollout protocol](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs). Rollouts are an internal compatibility surface; update the reader when their format changes.

## Tasks

- [x] Add fixture-based tests for Codex metadata, source labels, state transitions, partial writes, resumed files, and seen/dismissed behavior; observe failure before implementation.
- [x] Add native process/file discovery and an incremental rollout reader. Prefix Codex state IDs with `codex-` to avoid collisions. Preserve seen state until a newer rollout event.
- [x] Integrate FSEvents discovery into `SessionMonitor`, with closed-rollout cleanup and existing process-exit handling. Keep Claude transcript interruption detection scoped to Claude.
- [x] Route Codex Desktop clicks to `codex://threads/<id>`; keep terminal tab and VS Code folder routing. Update install/uninstall so a Codex-only machine does not need `claude`.
- [x] Document supported clients, launch instructions, default/custom `CODEX_HOME`, and permission/phone interaction limitations.
- [x] Run Swift tests, shell syntax checks, release app packaging and a read-only live Codex discovery check. Review the final diff.

## Review focus

- Same app-server process holds several sessions; losing one file must not remove siblings.
- Partial JSONL lines and large tool outputs must not corrupt state or require a full history read.
- Already-seen completion must not reappear on an unrelated filesystem event.
- Completed/aborted turns must override prior tool activity; background token events must preserve state.
- Historical, exec and subagent rollouts must not become pets.

## Verification and review

- `swift test`: 501 tests passed. Includes native process discovery with all three supported binary names, nested FSEvents, lifecycle reduction, partial/truncated writes, large completions, tail alignment, and seen-state process reassignment.
- Android `:core:test :app:testDebugUnitTest`: 309 core + 97 app tests passed; Kotlin compilation passed.
- Read-only live smoke: native discovery found three open rollouts and admitted the one interactive Codex Desktop session as running, excluding background/subagent records.
- `bash -n scripts/install.sh scripts/uninstall.sh` and `git diff --check` passed.
- Independent review found a large initial completion could be skipped. A regression first reproduced it, then passed after bounded line-start recovery was implemented.
- Final self-review found a resumed, already-seen conversation could retain its old process owner. A regression first reproduced it; synchronization now preserves seen state while updating ownership.
- Pure file-open/file-close changes without a write cannot be reliably observed by FSEvents. The README documents delayed discovery/cleanup until another log event or app restart; polling is intentionally absent.
- The real-process fixture's blocking Foundation `waitUntilExit()` stalled once under the parallel suite. Its cleanup now uses a bounded asynchronous liveness check; the full suite subsequently passed.
- Final `make app` completed; `codesign --verify --deep --strict dist/Critter.app` passed. The generated app is in `dist/Critter.app`; the installed application and Codex/Claude settings were not changed during development.
