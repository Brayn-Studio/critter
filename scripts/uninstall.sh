#!/usr/bin/env bash
# Reverses install.sh. Safe to run even if some or all of it was never installed --
# every removal step is independently best-effort (no step's absence aborts the rest).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Like install.sh: the install always lives in ~/.critter (CRITTER_HOME is test-only).
CRITTER_HOME="$HOME/.critter"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
PET_MARKER="<!-- critter-pet -->"

# First, before anything is removed (spec 6.7): put the status line back. If it can't be put
# back, stop here -- deleting ~/.critter would take the hook (and the backups) with it, and an
# older-form wrapper would then leave the user without a status line.
echo "==> Restoring the status line setting"
HOOK="$CRITTER_HOME/bin/critter-hook"
SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"
# Both wrapper forms contain "'<hook>' statusline"; slashes may be JSON-escaped, so match the name.
still_wrapped() { [ -f "$SETTINGS" ] && grep -qF "critter-hook' statusline" "$SETTINGS"; }
if [ ! -x "$HOOK" ] && still_wrapped; then
  # The hook is gone (say ~/.critter was deleted by hand) but its wrapper isn't: build one from
  # this checkout to undo it. Only if that fails too does the manual route below apply.
  echo "==> critter-hook is missing; building it to restore the status line"
  if (cd "$REPO" && swift build -c release --product critter-hook); then
    HOOK="$REPO/.build/release/critter-hook"
  fi
fi
if [ -x "$HOOK" ]; then
  "$HOOK" statusline-uninstall || true
fi
if still_wrapped; then
  CURRENT="$(plutil -extract statusLine.command raw -o - "$SETTINGS" 2>/dev/null || echo '(读不出来：settings.json 可能不是合法的 JSON)')"
  FIRST_BACKUP="$(ls "$CRITTER_HOME/backup" 2>/dev/null | grep '^settings\.json\.' | sort | head -n 1)"
  {
    echo
    echo "error: 没能还原 ${SETTINGS} 里的状态栏设置。卸载停在这里，还没有删除任何东西。"
    echo "现在的 statusLine.command 是："
    echo "    $CURRENT"
    echo "请手动还原，然后重新运行 make uninstall："
    echo "  - 带 \"statusline -- \" 的：把 command 改回它后面第一段单引号里的原命令（里面的 '\\'' 代表一个单引号 '）。"
    echo "  - 不带 \"--\" 的：说明接入前没有状态栏，把整个 \"statusLine\" 项删掉。"
    if [ -n "$FIRST_BACKUP" ]; then
      echo "  - Critter 改动前的 settings.json 备份在 ${CRITTER_HOME}/backup/，最早的一份是 ${FIRST_BACKUP}。"
    fi
  } >&2
  exit 1
fi

echo "==> Uninstalling the critter plugin"
command -v claude >/dev/null 2>&1 && claude plugin uninstall critter@critter-pet || true

echo "==> Removing the critter-pet marketplace"
command -v claude >/dev/null 2>&1 && claude plugin marketplace remove critter-pet || true

echo "==> Quitting and removing Critter.app"
killall Critter >/dev/null 2>&1 || true
# Bounded wait, so a still-exiting Critter can't write ~/.critter/app.json after it's removed.
for _ in $(seq 1 50); do pgrep -x Critter >/dev/null 2>&1 || break; sleep 0.1; done
if pgrep -x Critter >/dev/null 2>&1; then
  killall -9 Critter >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -x Critter >/dev/null 2>&1 || break; sleep 0.1; done
fi
# Unregister every copy Launch Services knows, so critter:// no longer resolves to one.
for app in "$HOME/Applications/Critter.app" "$REPO/dist/Critter.app"; do
  [ -d "$app" ] && "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
done
rm -rf "$HOME/Applications/Critter.app"

PET_CMD="$CLAUDE_CONFIG_DIR/commands/pet.md"
if [ -f "$PET_CMD" ] && grep -qF "$PET_MARKER" "$PET_CMD"; then
  echo "==> Removing the /pet command"
  rm -f "$PET_CMD"
fi

echo "==> Removing $CRITTER_HOME"
rm -rf "$CRITTER_HOME"

echo "==> Removing the login-item launch agent"
rm -f "$HOME/Library/LaunchAgents/local.critter.pet.plist"

echo "Critter 已卸载。仍然开着的 Claude Code 会话还加载着插件的 hooks（它们会静默跳过），重启这些会话即可完全卸干净。"
