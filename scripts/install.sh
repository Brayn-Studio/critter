#!/usr/bin/env bash
# Idempotent installer: builds Clawd.app and clawd-hook, installs them, registers the
# clawd:// URL scheme, installs the user-level /pet command (never touching a pet.md
# that isn't Clawd's own), and registers + installs the clawd Claude Code plugin (hooks
# + /pet's fallback explanation). A Clawd that is already running is restarted, so the
# new build takes over right away.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# The plugin's hooks run "$HOME/.clawd/bin/clawd-hook", and Clawd.app -- started by Launch
# Services, without this shell's environment -- reads ~/.clawd and ~/.claude. CLAWD_HOME and
# CLAUDE_CONFIG_DIR are test-only overrides that would split the hooks from the app, so the
# install always targets ~/.clawd.
if [ -n "${CLAWD_HOME:-}" ] && [ "$CLAWD_HOME" != "$HOME/.clawd" ]; then
  echo "warning: ignoring CLAWD_HOME=$CLAWD_HOME (test-only); installing to $HOME/.clawd" >&2
fi
CLAWD_HOME="$HOME/.clawd"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ "$CLAUDE_CONFIG_DIR" != "$HOME/.claude" ]; then
  echo "warning: CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR is set. /pet goes there, but Clawd.app always" >&2
  echo "         reads ~/.claude, so it won't see these sessions' names or sources." >&2
fi
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
  # Launch Services can take a moment to notice the old instance is gone; until then `open`
  # fails with -600. Retry (bounded) rather than abort the rest of the install.
  STARTED=0
  for _ in $(seq 1 20); do
    if open -g "$HOME/Applications/Clawd.app" 2>/dev/null; then STARTED=1; break; fi
    sleep 0.5
  done
  if [ "$STARTED" != 1 ]; then
    echo "warning: couldn't restart Clawd; start it with: open ~/Applications/Clawd.app" >&2
  fi
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

# Re-runnable: add the marketplace only if it isn't there yet (re-added if it points at another
# checkout), then refresh it so a bumped plugin version is seen before `plugin update`.
echo "==> Registering the clawd-pet marketplace"
MARKETPLACES="$(claude plugin marketplace list --json 2>/dev/null || true)"
if printf '%s' "$MARKETPLACES" | grep -q '"name"[[:space:]]*:[[:space:]]*"clawd-pet"'; then
  if ! printf '%s' "$MARKETPLACES" | grep -qF "\"$REPO\""; then
    echo "    (it points at another checkout; re-adding it from $REPO)"
    claude plugin marketplace remove clawd-pet || true
    claude plugin marketplace add "$REPO"
  fi
else
  claude plugin marketplace add "$REPO"
fi
claude plugin marketplace update clawd-pet

echo "==> Installing/updating the clawd plugin"
if claude plugin list --json 2>/dev/null | grep -q '"id"[[:space:]]*:[[:space:]]*"clawd@clawd-pet"'; then
  claude plugin update clawd@clawd-pet -y
else
  claude plugin install clawd@clawd-pet -y
fi

echo
echo "Clawd 已安装。已打开的 Claude Code 会话需要重启才会加载 hooks。"
