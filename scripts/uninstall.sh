#!/usr/bin/env bash
# Reverses install.sh. Safe to run even if some or all of it was never installed --
# every removal step is independently best-effort (no step's absence aborts the rest).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Like install.sh: the install always lives in ~/.clawd (CLAWD_HOME is test-only).
CLAWD_HOME="$HOME/.clawd"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
PET_MARKER="<!-- clawd-pet -->"

echo "==> Uninstalling the clawd plugin"
claude plugin uninstall clawd@clawd-pet || true

echo "==> Removing the clawd-pet marketplace"
claude plugin marketplace remove clawd-pet || true

echo "==> Quitting and removing Clawd.app"
killall Clawd >/dev/null 2>&1 || true
# Bounded wait, so a still-exiting Clawd can't write ~/.clawd/app.json after it's removed.
for _ in $(seq 1 50); do pgrep -x Clawd >/dev/null 2>&1 || break; sleep 0.1; done
if pgrep -x Clawd >/dev/null 2>&1; then
  killall -9 Clawd >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -x Clawd >/dev/null 2>&1 || break; sleep 0.1; done
fi
# Unregister every copy Launch Services knows, so clawd:// no longer resolves to one.
for app in "$HOME/Applications/Clawd.app" "$REPO/dist/Clawd.app"; do
  [ -d "$app" ] && "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
done
rm -rf "$HOME/Applications/Clawd.app"

PET_CMD="$CLAUDE_CONFIG_DIR/commands/pet.md"
if [ -f "$PET_CMD" ] && grep -qF "$PET_MARKER" "$PET_CMD"; then
  echo "==> Removing the /pet command"
  rm -f "$PET_CMD"
fi

echo "==> Removing $CLAWD_HOME"
rm -rf "$CLAWD_HOME"

echo "==> Removing the login-item launch agent"
rm -f "$HOME/Library/LaunchAgents/local.clawd.pet.plist"

echo "Clawd 已卸载。仍然开着的 Claude Code 会话还加载着插件的 hooks（它们会静默跳过），重启这些会话即可完全卸干净。"
