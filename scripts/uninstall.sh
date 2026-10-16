#!/usr/bin/env bash
# Reverses install.sh. Safe to run even if some or all of it was never installed --
# every removal step is independently best-effort (no step's absence aborts the rest).
set -uo pipefail

CLAWD_HOME="${CLAWD_HOME:-$HOME/.clawd}"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PET_MARKER="<!-- clawd-pet -->"

echo "==> Uninstalling the clawd plugin"
claude plugin uninstall clawd@clawd-pet || true

echo "==> Removing the clawd-pet marketplace"
claude plugin marketplace remove clawd-pet || true

echo "==> Quitting and removing Clawd.app"
killall Clawd >/dev/null 2>&1 || true
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

echo "Clawd 已卸载。"
