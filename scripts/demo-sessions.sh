#!/usr/bin/env bash
# Fakes Claude Code sessions for the pet, without running Claude: each demo session is a
# `sleep 3600` process (standing in for the claude process, so exit detection works) plus
# an atomically written state file $CLAWD_HOME/sessions/demo-<i>.json.
#
#   demo-sessions.sh N [state…]          replace any demo sessions with N new ones; states
#                                        default to waiting/done/running/idle/error, cycling
#   demo-sessions.sh set <i> <state> [detail]
#                                        change demo-<i>'s state (and bubble text)
#   demo-sessions.sh transcript <i> <path>
#                                        give demo-<i> a transcriptPath (file is created if
#                                        missing), e.g. to simulate an Esc interrupt by
#                                        appending Claude's interrupt line to it
#   demo-sessions.sh pid <i>             print demo-<i>'s stand-in process id
#   demo-sessions.sh clean               kill the stand-in processes, delete the state (and
#                                        lock) files
set -euo pipefail

CLAWD_HOME="${CLAWD_HOME:-$HOME/.clawd}"
SESSIONS="$CLAWD_HOME/sessions"
PIDS_FILE="$CLAWD_HOME/demo.pids"
DEFAULT_STATES=(waiting done running idle error)

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }

default_detail() {
  case "$1" in
    waiting) echo "需要你确认：Bash(npm test)" ;;
    done) echo "做完了：全部测试通过。" ;;
    running) echo "Bash: npm test" ;;
    error) echo "出错了：API 超时" ;;
    *) echo "" ;;
  esac
}

valid_state() {
  case "$1" in idle|running|waiting|done|error) return 0 ;; *) return 1 ;; esac
}

# Atomic write: same-directory temp file, then rename over the target (like StateStore).
write_atomic() {
  local target="$1" json="$2"
  local tmp="$SESSIONS/.$(basename "$target").tmp-$$"
  printf '%s\n' "$json" > "$tmp"
  mv -f "$tmp" "$target"
}

state_file() { echo "$SESSIONS/demo-$1.json"; }

require_session() {
  local file
  file="$(state_file "$1")"
  if [ ! -f "$file" ]; then
    echo "no demo session $1 ($file)" >&2
    exit 1
  fi
}

clean() {
  # State files go first, so the app's exit handling (triggered by the kills below) finds
  # nothing left to delete and doesn't re-create lock files for them.
  rm -f "$SESSIONS"/demo-*.json
  if [ -f "$PIDS_FILE" ]; then
    while read -r pid; do
      [ -n "$pid" ] || continue
      # Only kill it if that pid is still one of our sleeps (never a reused pid).
      if [ "$(ps -p "$pid" -o comm= 2>/dev/null | xargs basename 2>/dev/null || true)" = "sleep" ]; then
        kill "$pid" 2>/dev/null || true
      fi
    done < "$PIDS_FILE"
    rm -f "$PIDS_FILE"
  fi
  # StateStore never unlinks its per-session lock files; nothing else uses demo ones.
  rm -f "$CLAWD_HOME"/locks/demo-*.lock
}

start() {
  local count="$1"; shift
  local states=("$@")
  [ "${#states[@]}" -gt 0 ] || states=("${DEFAULT_STATES[@]}")
  for s in "${states[@]}"; do valid_state "$s" || { echo "bad state: $s" >&2; exit 2; }; done

  clean
  mkdir -p "$SESSIONS"
  local base i state pid detail
  base="$(now_ms)"
  for ((i = 1; i <= count; i++)); do
    state="${states[$(((i - 1) % ${#states[@]}))]}"
    sleep 3600 >/dev/null 2>&1 &
    pid=$!
    echo "$pid" >> "$PIDS_FILE"
    detail="$(default_detail "$state")"
    write_atomic "$(state_file "$i")" "$(jq -nc \
      --arg id "demo-$i" --arg cwd "/tmp/demo-$i" --arg state "$state" --arg detail "$detail" \
      --argjson now "$(now_ms)" --argjson created "$((base + i))" --argjson pid "$pid" \
      '{schema: 1, sessionId: $id, cwd: $cwd, state: $state,
        detail: (if $detail == "" then null else $detail end),
        lastEvent: "Demo", eventTime: $now, createdAt: $created, claudePid: $pid}')"
    echo "demo-$i: $state (pid $pid)"
  done
}

set_state() {
  local i="$1" state="$2"
  local detail="${3-$(default_detail "$state")}"
  valid_state "$state" || { echo "bad state: $state" >&2; exit 2; }
  require_session "$i"
  local file
  file="$(state_file "$i")"
  write_atomic "$file" "$(jq -c --arg state "$state" --arg detail "$detail" --argjson now "$(now_ms)" \
    '.state = $state | .detail = (if $detail == "" then null else $detail end)
     | .lastEvent = "Demo" | .eventTime = $now' "$file")"
  echo "demo-$i: $state"
}

set_transcript() {
  local i="$1" path="$2"
  require_session "$i"
  mkdir -p "$(dirname "$path")"
  [ -f "$path" ] || : > "$path"
  local file
  file="$(state_file "$i")"
  write_atomic "$file" "$(jq -c --arg path "$path" '.transcriptPath = $path' "$file")"
  echo "demo-$i: transcriptPath=$path"
}

[ $# -ge 1 ] || usage
case "$1" in
  clean) clean; echo "demo sessions removed" ;;
  set) [ $# -ge 3 ] || usage; set_state "$2" "$3" "${@:4}" ;;
  transcript) [ $# -eq 3 ] || usage; set_transcript "$2" "$3" ;;
  pid) [ $# -eq 2 ] || usage; require_session "$2"; jq -r '.claudePid' "$(state_file "$2")" ;;
  ''|*[!0-9]*) usage ;;
  *) start "$@" ;;
esac
