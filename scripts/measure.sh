#!/usr/bin/env bash
# Prints Clawd's memory footprint (the number Activity Monitor's "Memory" column shows)
# and its average CPU usage over 10 samples, per the Global Constraints' memory/CPU budget.
set -euo pipefail

PID="$(pgrep -x Clawd | head -1 || true)"
if [ -z "$PID" ]; then
  echo "Clawd is not running (pgrep -x Clawd found nothing)" >&2
  exit 1
fi
echo "pid: $PID"

FOOTPRINT_LINE="$(footprint -p "$PID" 2>/dev/null | grep -i 'phys_footprint:' | head -1 || true)"
echo "footprint: ${FOOTPRINT_LINE:-unavailable (footprint may require sudo)}"

SAMPLES=10
TOTAL=0
for _ in $(seq 1 "$SAMPLES"); do
  CPU="$(ps -o %cpu= -p "$PID" 2>/dev/null | tr -d ' ')"
  CPU="${CPU:-0}"
  TOTAL="$(awk -v t="$TOTAL" -v c="$CPU" 'BEGIN { printf "%.4f", t + c }')"
  sleep 0.3
done
AVG="$(awk -v t="$TOTAL" -v n="$SAMPLES" 'BEGIN { printf "%.4f", t / n }')"
echo "cpu avg over $SAMPLES samples (0.3s apart): ${AVG}%"
