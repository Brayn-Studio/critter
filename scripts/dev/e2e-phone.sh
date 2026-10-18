#!/usr/bin/env bash
# End-to-end check of phone answering against a REAL interactive Claude Code session
# (`claude --model haiku`, driven through tmux), with `critter-bridge-client` standing in
# for the phone. Prints one `PASS <name>` / `FAIL <name>: <reason>` line per scenario, plus
# `INFO` lines for what the two exploratory scenarios (question-multi, subagent-permission)
# observed.
#
# Prerequisites: `make install` has run (plugin 0.3.0 with the `ask` hook), Critter is
# running, `defaults write local.critter.pet debugEnabled -bool true`, `claude` and `tmux`
# are on PATH. It turns the bridge on for the run and puts it back afterwards. The Claude
# session also shows up on claude.ai while it runs (the user's Remote Control setting).
#
#   scripts/dev/e2e-phone.sh [scenario ...]      # default: all, in order
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLIENT="${CRITTER_BRIDGE_CLIENT:-$REPO/.build/debug/critter-bridge-client}"
SOCK="critter-e2e-$$"
SESS="critter-e2e"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/critter-e2e.XXXXXX")"
DIR="$WORK/proj"
FEED="$WORK/watch.jsonl"
OUT="${E2E_SCREENS:-$WORK/out}"
mkdir -p "$DIR" "$OUT"
DOMAIN=local.critter.pet
BASE_PLANS="$(ls ~/.claude/plans 2>/dev/null | sort)"
WATCH_PID=""
PREV_BRIDGE="$(defaults read "$DOMAIN" bridgeEnabled 2>/dev/null || echo 0)"
FAILED=0
PARENT=""

T() { tmux -L "$SOCK" "$@"; }

cleanup() {
  if T has-session -t "$SESS" 2>/dev/null; then
    T send-keys -t "$SESS" Escape 2>/dev/null; sleep 0.5
    T send-keys -t "$SESS" -l '/exit' 2>/dev/null; sleep 0.3
    T send-keys -t "$SESS" Enter 2>/dev/null; sleep 3
  fi
  T kill-server 2>/dev/null
  [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
  # This run's transcript directory (named after the real path of the scratch dir).
  local real; real="$(cd "$DIR" 2>/dev/null && pwd -P)"
  if [ -n "$real" ]; then
    local enc; enc="$(printf '%s' "$real" | sed 's/[^A-Za-z0-9]/-/g')"
    rm -rf "$HOME/.claude/projects/$enc"
  fi
  # Plan files the session created.
  local f
  for f in $(ls ~/.claude/plans 2>/dev/null | sort); do
    printf '%s\n' "$BASE_PLANS" | grep -qxF "$f" || rm -f "$HOME/.claude/plans/$f"
  done
  rm -rf "$WORK"
  if [ "$PREV_BRIDGE" != 1 ]; then open -g "critter://debug-set?bridgeEnabled=0"; fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- helpers

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; FAILED=$((FAILED + 1)); save_screen "fail-$1"; }
info() { echo "INFO $1"; }
save_screen() { screen > "$OUT/$1.txt" 2>/dev/null; }

screen() { T capture-pane -p -t "$SESS" 2>/dev/null; }
has_screen() { screen | grep -Eq -- "$1"; }
# wait_for <timeout s> <command...>: polls until the command succeeds or time is up.
wait_for() {
  local limit=$1 n=0; shift
  until "$@" || [ $n -ge "$limit" ]; do sleep 1; n=$((n + 1)); done
  "$@"
}
wait_screen() { wait_for "$1" has_screen "$2"; }
not_in_plan_mode() { ! has_screen 'plan mode on'; }

type_prompt() { T send-keys -t "$SESS" -l "$1"; sleep 0.4; T send-keys -t "$SESS" Enter; }

# The newest snapshot line the client saw.
last_snapshot() { grep '"type":"snapshot"' "$FEED" 2>/dev/null | tail -n 1; }
# pending_json [kind]: JSON array of the pending requests (of that kind).
pending_json() {
  last_snapshot | python3 -I -c '
import json, sys
kind = sys.argv[1]
line = sys.stdin.read().strip()
out = []
if line:
    for p in json.loads(line).get("pending", []):
        if kind and p["kind"] != kind: continue
        out.append(p)
print(json.dumps(out))' "${1:-}"
}
pending_ids() { pending_json "${1:-}" | python3 -I -c 'import json,sys; print(" ".join(p["requestId"] for p in json.load(sys.stdin)))'; }
has_pending() { [ -n "$(pending_ids "${1:-}")" ]; }
first_pending() { pending_ids "${1:-}" | awk '{print $1}'; }
request_field() { # <requestId> <python expression over p>
  pending_json | python3 -I -c '
import json, sys
for p in json.load(sys.stdin):
    if p["requestId"] == sys.argv[1]:
        print(eval(sys.argv[2])); break' "$1" "$2"
}
req_exists() { pending_json | grep -q "\"$1\""; }
req_gone() { ! req_exists "$1"; }
# A pending request of <kind> that is not one of the ids after it.
new_pending() { # <kind> <known ids...>
  local kind=$1; shift
  local id
  for id in $(pending_ids "$kind"); do
    case " $* " in *" $id "*) ;; *) echo "$id"; return 0 ;; esac
  done
  return 1
}

answer() { "$CLIENT" answer "$@" >/dev/null; }

# Waits for a pending request and prints its id.
await_request() { # <kind> <timeout>
  local n=0 id
  while [ $n -lt "$2" ]; do
    id="$(first_pending "$1")"; [ -n "$id" ] && { echo "$id"; return 0; }
    sleep 1; n=$((n + 1))
  done
  return 1
}

# Allows any permission requests until the session is quiet: no request and no work in
# progress for a few seconds.
settle() { # <timeout>
  local n=0 quiet=0 id
  while [ $n -lt "$1" ]; do
    id="$(first_pending permission)"
    if [ -n "$id" ]; then answer "$id" --decision allow; quiet=0
    elif has_pending || has_screen 'esc to interrupt|[✻✽✶✳✢·*] [A-Za-z]+… |Running…'; then quiet=0
    else quiet=$((quiet + 1)); fi
    [ $quiet -ge 4 ] && return 0
    sleep 1; n=$((n + 1))
  done
  return 1
}

# Back to the default permission mode (BTab cycles default -> accept edits -> plan).
ensure_default_mode() {
  local i
  for i in 1 2 3 4; do
    has_screen 'accept edits on|plan mode on|auto mode on|bypass' || return 0
    T send-keys -t "$SESS" BTab; sleep 1
  done
}

clean_slate() {
  settle 90 || { T send-keys -t "$SESS" Escape; sleep 2; }
  ensure_default_mode
}

# ---------------------------------------------------------------- setup

[ -x "$CLIENT" ] || (cd "$REPO" && swift build --product critter-bridge-client >/dev/null 2>&1)
[ -x "$CLIENT" ] || { echo "no critter-bridge-client at $CLIENT"; exit 2; }
command -v tmux >/dev/null && command -v claude >/dev/null || { echo "needs tmux and claude on PATH"; exit 2; }
[ "$(defaults read "$DOMAIN" debugEnabled 2>/dev/null)" = 1 ] || { echo "needs: defaults write $DOMAIN debugEnabled -bool true"; exit 2; }
pgrep -x Critter >/dev/null || { echo "Critter is not running"; exit 2; }

open -g "critter://debug-set?bridgeEnabled=1"
sleep 2
if ! "$CLIENT" watch --count 1 >/dev/null 2>&1; then
  rm -f "$WORK/pair.json"
  open -g "critter://debug-bridge-pair?out=$WORK/pair.json"
  wait_for 20 test -s "$WORK/pair.json" || { echo "could not get a pairing URI"; exit 2; }
  URI="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["uri"])' "$WORK/pair.json")"
  "$CLIENT" pair "$URI" >/dev/null || { echo "pairing failed"; exit 2; }
fi

"$CLIENT" watch > "$FEED" 2>/dev/null &
WATCH_PID=$!
wait_for 15 test -s "$FEED" || { echo "the client got no snapshot"; exit 2; }

T new-session -d -s "$SESS" -x 150 -y 45 -c "$DIR" \
  "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_BRIDGE_SESSION_ID -u CLAUDE_CODE_EXECPATH -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_PID -u CLAUDE_EFFORT claude --permission-mode default --model haiku --name critter-e2e; sleep 600"

# Trust dialog (new directory), then the input prompt.
wait_screen 40 'Yes, I trust|for shortcuts' || { echo "claude did not start"; save_screen startup; exit 2; }
if has_screen 'Yes, I trust'; then
  T send-keys -t "$SESS" Down; sleep 0.5; T send-keys -t "$SESS" Enter
fi
wait_for 40 has_screen 'for shortcuts|\? for|esc to|permission|Try "' || { echo "claude has no prompt"; save_screen startup; exit 2; }
sleep 3

# The parent session: the one Critter tracks for our scratch directory. It registers on its
# first hook event, so give it a harmless turn first.
base="$(basename "$DIR")"
find_parent() {
  PARENT="$(last_snapshot | python3 -I -c '
import json, sys
line = sys.stdin.read().strip()
for s in (json.loads(line).get("sessions", []) if line else []):
    if s.get("cwd", "").endswith(sys.argv[1]) or s.get("name") == sys.argv[1]:
        print(s["id"]); break' "$base")"
  [ -n "$PARENT" ]
}
type_prompt 'Reply with the single word READY.'
wait_screen 60 'READY' || true
wait_for 20 find_parent || { echo "Critter never listed the session (cwd .../$base)"; save_screen setup; exit 2; }
info "parent session $PARENT"

# ---------------------------------------------------------------- scenarios

s_permission_allow() {
  clean_slate
  type_prompt 'Run this exact bash command and nothing else: touch e2e-1.txt'
  local id; id="$(await_request permission 90)" || { fail permission-allow "no permission request"; return; }
  answer "$id" --decision allow
  wait_for 30 test -f "$DIR/e2e-1.txt" || { fail permission-allow "file was not created after allow"; return; }
  wait_for 5 req_gone "$id" || { fail permission-allow "request still in the snapshot"; return; }
  pass permission-allow
}

s_permission_deny_message() {
  clean_slate
  type_prompt 'Run this exact bash command and nothing else: touch e2e-2.txt'
  local id; id="$(await_request permission 90)" || { fail permission-deny-message "no permission request"; return; }
  answer "$id" --decision deny --message '换个文件名'
  wait_screen 30 '换个文件名' && pass permission-deny-message || fail permission-deny-message "message not on screen"
}

s_question_single() {
  clean_slate
  type_prompt 'Use the AskUserQuestion tool to ask one question, "Pick one", with exactly two options: One and Two. Do nothing else.'
  local id; id="$(await_request question 90)" || { fail question-single "no question request"; return; }
  local q; q="$(request_field "$id" 'p["input"]["questions"][0]["question"]')"
  answer "$id" --answer "$q=Two"
  wait_screen 30 '→ Two' && pass question-single || fail question-single "no '→ Two' on screen"
}

s_question_multi() {
  local prompt='Use the AskUserQuestion tool to ask one question, "Pick letters", with multiSelect set to true and exactly three options: A, B and C. After you get the answer, reply with one line RECEIVED=<the answer you got, exactly as given to you> and nothing else.'
  local format value ok=""
  for format in joined-comma-space joined-comma json-array; do
    case $format in
      joined-comma-space) value='A, B' ;;
      joined-comma) value='A,B' ;;
      json-array) value='["A","B"]' ;;
    esac
    clean_slate
    type_prompt "$prompt"
    local id; id="$(await_request question 90)" || { info "question-multi [$format]: no question request"; continue; }
    local q; q="$(request_field "$id" 'p["input"]["questions"][0]["question"]')"
    info "question-multi request input: $(request_field "$id" 'json.dumps(p["input"])')"
    answer "$id" --answer "$q=$value"
    wait_screen 90 'RECEIVED=[A-C"\[]' || { info "question-multi [$format]: no RECEIVED line"; save_screen "multi-$format"; continue; }
    sleep 2
    save_screen "multi-$format"
    local shown recv
    shown="$(screen | grep -E '^ *(→|⎿).*[AB]' | head -3 | tr '\n' '|')"
    recv="$(screen | grep -E 'RECEIVED=[A-C"\[]' | tail -1 | sed 's/^[^R]*//')"
    info "question-multi [$format] sent '$value' -> screen: ${shown} claude: ${recv}"
    if printf '%s' "$recv" | grep -q 'A' && printf '%s' "$recv" | grep -q 'B'; then ok="$format"; break; fi
  done
  if [ -n "$ok" ]; then info "question-multi FORMAT=$ok"; pass question-multi
  else fail question-multi "Claude received both labels in none of the three formats"; fi
}

s_question_free_text() {
  clean_slate
  type_prompt 'Use the AskUserQuestion tool to ask one question, "Favorite fruit?", with options Apple and Pear. After you get the answer, reply with one line FRUIT=<the answer> and nothing else.'
  local id; id="$(await_request question 90)" || { fail question-free-text "no question request"; return; }
  local q; q="$(request_field "$id" 'p["input"]["questions"][0]["question"]')"
  answer "$id" --answer "$q=Mango"
  wait_screen 60 'FRUIT=Mango' && pass question-free-text || fail question-free-text "Claude did not repeat Mango"
}

s_plan_revise_then_approve() {
  clean_slate
  T send-keys -t "$SESS" BTab; sleep 1; T send-keys -t "$SESS" BTab; sleep 1
  has_screen 'plan mode' || { fail plan-revise-then-approve "could not enter plan mode"; return; }
  type_prompt 'Plan how to create a file e2e-plan.txt containing the word hello, then call ExitPlanMode with the plan. Keep the plan to three lines.'
  local id; id="$(await_request plan 120)" || { fail plan-revise-then-approve "no plan request"; return; }
  answer "$id" --decision revise --message 'Also make the file contain a second line: world'
  local id2="" n=0
  while [ $n -lt 150 ]; do
    id2="$(new_pending plan "$id")" && break
    id2=""; sleep 1; n=$((n + 1))
  done
  [ -n "$id2" ] || { fail plan-revise-then-approve "plan was not resubmitted"; return; }
  request_field "$id2" 'p["input"].get("plan","")' | grep -qi world || info "plan-revise: resubmitted plan does not mention world"
  answer "$id2" --decision approve
  wait_for 150 not_in_plan_mode || { fail plan-revise-then-approve "still in plan mode after approve"; return; }
  settle 120 || true
  pass plan-revise-then-approve
}

ask_pids() { pgrep -f 'critter-hook ask' | sort | tr '\n' ' '; }
new_ask_pids() { # <before>
  local pid out=""
  for pid in $(ask_pids); do case " $1 " in *" $pid "*) ;; *) out="$out $pid" ;; esac; done
  echo "$out"
}

s_terminal_first() {
  clean_slate
  local before; before="$(ask_pids)"
  type_prompt 'Run this exact bash command and nothing else: touch e2e-7.txt'
  local id; id="$(await_request permission 90)" || { fail terminal-first "no permission request"; return; }
  sleep 1
  T send-keys -t "$SESS" Enter
  wait_for 30 test -f "$DIR/e2e-7.txt" || { fail terminal-first "file not created after Enter in the terminal"; return; }
  wait_for 2 req_gone "$id" || { fail terminal-first "request still pending 2 s after the tool finished"; return; }
  local extra; extra="$(new_ask_pids "$before")"
  [ -n "$extra" ] && { sleep 2; extra="$(new_ask_pids "$before")"; }
  [ -z "$extra" ] && pass terminal-first || fail terminal-first "ask process(es) still running:$extra"
}

s_escape_clears() {
  clean_slate
  type_prompt 'Run this exact bash command and nothing else: touch e2e-8.txt'
  local id; id="$(await_request permission 90)" || { fail escape-clears "no permission request"; return; }
  sleep 1
  T send-keys -t "$SESS" Escape
  wait_for 2 req_gone "$id" && pass escape-clears || fail escape-clears "request still pending 2 s after Esc"
}

s_subagent_permission() {
  clean_slate
  type_prompt 'Launch a subagent with the Agent tool whose only job is to run this bash command: touch e2e-sub.txt. Wait for it and then say DONE-SUB.'
  local id; id="$(await_request permission 120)" || { fail subagent-permission "no permission request"; return; }
  local sid tool input
  sid="$(request_field "$id" 'p["sessionId"]')"
  tool="$(request_field "$id" 'p["toolName"]')"
  input="$(request_field "$id" 'json.dumps(p["input"])')"
  if [ "$sid" = "$PARENT" ]; then info "subagent-permission: sessionId == parent session id ($sid); tool=$tool input=$input"
  else info "subagent-permission: sessionId $sid != parent $PARENT; tool=$tool input=$input"; fi
  answer "$id" --decision allow
  settle 120 || true
  pass subagent-permission
}

s_say() {
  clean_slate
  "$CLIENT" say "$PARENT" 'Reply with only the single word you get by joining PINE and APPLE, in capital letters.' >/dev/null \
    || { fail say "client say failed"; return; }
  wait_screen 60 'PINEAPPLE' && pass say || fail say "no PINEAPPLE on screen"
}

ALL="permission_allow permission_deny_message question_single question_multi question_free_text plan_revise_then_approve terminal_first escape_clears subagent_permission say"
for name in ${*:-$ALL}; do "s_${name//-/_}"; done

echo "scenarios failed: $FAILED"
[ "$FAILED" -eq 0 ]
