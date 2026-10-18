#!/usr/bin/env bash
# Idempotent installer: builds Critter.app and critter-hook, installs them, registers the
# critter:// URL scheme, installs the user-level /pet command (never touching a pet.md
# that isn't Critter's own), and registers + installs the critter Claude Code plugin (hooks
# + /pet's fallback explanation). A Critter that is already running is restarted, so the
# new build takes over right away.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# The plugin's hooks run "$HOME/.critter/bin/critter-hook", and Critter.app -- started by Launch
# Services, without this shell's environment -- reads ~/.critter and ~/.claude. CRITTER_HOME and
# CLAUDE_CONFIG_DIR are test-only overrides that would split the hooks from the app, so the
# install always targets ~/.critter.
if [ -n "${CRITTER_HOME:-}" ] && [ "$CRITTER_HOME" != "$HOME/.critter" ]; then
  echo "warning: ignoring CRITTER_HOME=$CRITTER_HOME (test-only); installing to $HOME/.critter" >&2
fi
CRITTER_HOME="$HOME/.critter"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ "$CLAUDE_CONFIG_DIR" != "$HOME/.claude" ]; then
  echo "warning: CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR is set. /pet goes there, but Critter.app always" >&2
  echo "         reads ~/.claude, so it won't see these sessions' names or sources." >&2
fi
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
PET_MARKER="<!-- critter-pet -->"

echo "==> Building Critter.app"
make app

WAS_RUNNING=0
if pgrep -x Critter >/dev/null 2>&1; then WAS_RUNNING=1; fi

echo "==> Installing Critter.app to ~/Applications"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Critter.app"
cp -R "$REPO/dist/Critter.app" "$HOME/Applications/Critter.app"

echo "==> Registering the critter:// URL scheme"
"$LSREGISTER" -f "$HOME/Applications/Critter.app"

if [ "$WAS_RUNNING" = 1 ]; then
  echo "==> Restarting the running Critter"
  killall Critter >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do pgrep -x Critter >/dev/null 2>&1 || break; sleep 0.1; done
  # Launch Services can take a moment to notice the old instance is gone; until then `open`
  # fails with -600. Retry (bounded) rather than abort the rest of the install.
  STARTED=0
  for _ in $(seq 1 20); do
    if open -g "$HOME/Applications/Critter.app" 2>/dev/null; then STARTED=1; break; fi
    sleep 0.5
  done
  if [ "$STARTED" != 1 ]; then
    echo "warning: couldn't restart Critter; start it with: open ~/Applications/Critter.app" >&2
  fi
fi

echo "==> Building and installing critter-hook to $CRITTER_HOME/bin"
swift build -c release --product critter-hook
mkdir -p "$CRITTER_HOME/bin"
cp "$REPO/.build/release/critter-hook" "$CRITTER_HOME/bin/critter-hook"
"$CRITTER_HOME/bin/critter-hook" statusline-install || echo "warning: 状态栏数据未接入" >&2

echo "==> Installing the /pet command"
mkdir -p "$CLAUDE_CONFIG_DIR/commands"
PET_CMD="$CLAUDE_CONFIG_DIR/commands/pet.md"
if [ -f "$PET_CMD" ] && ! grep -qF "$PET_MARKER" "$PET_CMD"; then
  echo "error: $PET_CMD already exists and wasn't installed by Critter (no $PET_MARKER marker)." >&2
  echo "Move it aside, then re-run install -- otherwise it would conflict with Critter's /pet." >&2
  exit 1
fi
cp "$REPO/Support/pet-command.md" "$PET_CMD"

# Re-runnable: add the marketplace only if it isn't there yet (re-added if it points at another
# checkout), then refresh it so a bumped plugin version is seen before `plugin update`.
echo "==> Registering the critter-pet marketplace"
MARKETPLACES="$(claude plugin marketplace list --json 2>/dev/null || true)"
if printf '%s' "$MARKETPLACES" | grep -q '"name"[[:space:]]*:[[:space:]]*"critter-pet"'; then
  if ! printf '%s' "$MARKETPLACES" | grep -qF "\"$REPO\""; then
    echo "    (it points at another checkout; re-adding it from $REPO)"
    claude plugin marketplace remove critter-pet || true
    claude plugin marketplace add "$REPO"
  fi
else
  claude plugin marketplace add "$REPO"
fi
claude plugin marketplace update critter-pet

echo "==> Installing/updating the critter plugin"
if claude plugin list --json 2>/dev/null | grep -q '"id"[[:space:]]*:[[:space:]]*"critter@critter-pet"'; then
  claude plugin update critter@critter-pet -y
else
  claude plugin install critter@critter-pet -y
fi

echo
echo "Critter 已安装。已打开的 Claude Code 会话需要重启才会加载 hooks。"
