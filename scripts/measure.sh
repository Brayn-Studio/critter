#!/usr/bin/env bash
# Prints Clawd's memory footprint (the number Activity Monitor's "Memory" column shows)
# and its average CPU usage over 10 samples, per the Global Constraints' memory/CPU budget
# (≤ 50 MB with 5 sessions expanded and animating; idle CPU ≈ 0, animating < 1%).
#
#   measure.sh                  measure Clawd as it is
#   measure.sh --sessions N     first replace the demo sessions with N fake ones
#                               (scripts/demo-sessions.sh; 0 removes them), give the pet a
#                               few seconds to settle, then measure. The demo sessions stay
#                               (remove them with scripts/demo-sessions.sh clean).
#
# Whether N sessions show expanded depends on the merge threshold (settings, default 4)
# and on any real Claude sessions also on screen.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTLE_SECONDS=3

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

SESSIONS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sessions)
      [ $# -ge 2 ] || usage
      SESSIONS="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done
case "$SESSIONS" in
  '') ;;
  *[!0-9]*) usage ;;
esac

PID="$(pgrep -x Clawd | head -1 || true)"
if [ -z "$PID" ]; then
  echo "Clawd is not running (pgrep -x Clawd found nothing)" >&2
  exit 1
fi
echo "pid: $PID"

if [ -n "$SESSIONS" ]; then
  if [ "$SESSIONS" -eq 0 ]; then
    "$ROOT/scripts/demo-sessions.sh" clean >/dev/null
  else
    "$ROOT/scripts/demo-sessions.sh" "$SESSIONS" >/dev/null
  fi
  echo "demo sessions: $SESSIONS (settling ${SETTLE_SECONDS}s)"
  sleep "$SETTLE_SECONDS"
fi

FOOTPRINT_LINE="$(footprint -p "$PID" 2>/dev/null | grep -i 'phys_footprint:' | head -1 || true)"
echo "footprint: ${FOOTPRINT_LINE:-unavailable (footprint may require sudo)}"

SAMPLES=10
TOTAL=0
for _ in $(seq 1 "$SAMPLES"); do
  CPU="$(ps -o %cpu= -p "$PID" 2>/dev/null | tr -d ' ' || true)"
  CPU="${CPU:-0}"
  TOTAL="$(awk -v t="$TOTAL" -v c="$CPU" 'BEGIN { printf "%.4f", t + c }')"
  sleep 0.3
done
AVG="$(awk -v t="$TOTAL" -v n="$SAMPLES" 'BEGIN { printf "%.4f", t / n }')"
echo "cpu avg over $SAMPLES samples (0.3s apart): ${AVG}%"
