#!/usr/bin/env bash
# Idempotent installer: builds Clawd.app and clawd-hook, installs them, registers the
# clawd:// URL scheme, installs the user-level /pet command (never touching a pet.md
# that isn't Clawd's own), and registers + installs the clawd Claude Code plugin (hooks
# + /pet's fallback explanation). A Clawd that is already running is restarted, so the
# new build takes over right away.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

CLAWD_HOME="${CLAWD_HOME:-$HOME/.clawd}"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
PET_MARKER="<!-- clawd-pet -->"

echo "==> Building Clawd.app"
make app

WAS_RUNNING=0
if pgrep -x Clawd >/dev/null 2>&1; then WAS_RUNNING=1; fi

echo "==> Installing Clawd.app to ~/Applications"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Clawd.app"
cp -R "$REPO/dist/Clawd.app" "$HOME/Applications/Clawd.app"

echo "==> Registering the clawd:// URL scheme"
"$LSREGISTER" -f "$HOME/Applications/Clawd.app"

if [ "$WAS_RUNNING" = 1 ]; then
  echo "==> Restarting the running Clawd"
  killall Clawd >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do pgrep -x Clawd >/dev/null 2>&1 || break; sleep 0.1; done
  open -g "$HOME/Applications/Clawd.app"
fi

echo "==> Building and installing clawd-hook to $CLAWD_HOME/bin"
swift build -c release --product clawd-hook
mkdir -p "$CLAWD_HOME/bin"
cp "$REPO/.build/release/clawd-hook" "$CLAWD_HOME/bin/clawd-hook"

echo "==> Installing the /pet command"
mkdir -p "$CLAUDE_CONFIG_DIR/commands"
PET_CMD="$CLAUDE_CONFIG_DIR/commands/pet.md"
if [ -f "$PET_CMD" ] && ! grep -qF "$PET_MARKER" "$PET_CMD"; then
  echo "error: $PET_CMD already exists and wasn't installed by Clawd (no $PET_MARKER marker)." >&2
  echo "Move it aside, then re-run install -- otherwise it would conflict with Clawd's /pet." >&2
  exit 1
fi
cp "$REPO/Support/pet-command.md" "$PET_CMD"

echo "==> Registering the clawd-pet marketplace"
claude plugin marketplace add "$REPO"

echo "==> Installing/updating the clawd plugin"
if claude plugin list --json 2>/dev/null | grep -q '"id"[[:space:]]*:[[:space:]]*"clawd@clawd-pet"'; then
  claude plugin update clawd@clawd-pet -y
else
  claude plugin install clawd@clawd-pet -y
fi

echo
echo "Clawd 已安装。已打开的 Claude Code 会话需要重启才会加载 hooks。"
