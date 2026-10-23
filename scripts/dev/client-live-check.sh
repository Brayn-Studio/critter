#!/usr/bin/env bash
# Checks CritterClient (the iOS app's connection code) against the REAL Critter on this Mac:
# `LiveBridgeTests` reads the certificate, pairs a throwaway `critter-bridge-client` device over
# the pinned URLSession transport, connects with BridgeClient, waits for a snapshot and gets the
# Mac's reply to a command. The device is unpaired again at the end.
#
# Prerequisites: Critter is running, `defaults write local.critter.pet debugEnabled -bool true`.
# It turns the phone bridge on for the run if it was off, and back off afterwards.
#
#   scripts/dev/client-live-check.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOMAIN=local.critter.pet
# The user's own temp directory: Critter only writes the pairing file under it (or ~/.critter).
TMPROOT="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "${TMPDIR:-/tmp}/")"
WORK="$(mktemp -d "${TMPROOT%/}/critter-client-live.XXXXXX")"
DEVICES="${CRITTER_HOME:-$HOME/.critter}/bridge/devices.json"
PREV_BRIDGE="$(defaults read "$DOMAIN" bridgeEnabled 2>/dev/null || echo 0)"
TURNED_ON=0

# wait_for <timeout s> <command...>: polls until the command succeeds or time is up.
wait_for() {
  local limit=$1 n=0; shift
  until "$@" || [ $n -ge "$limit" ]; do sleep 1; n=$((n + 1)); done
  "$@"
}

# Whether Critter's devices file no longer lists <deviceId>.
unpaired() {
  python3 -I -c '
import json, sys
sys.exit(1 if any(d.get("id") == sys.argv[2] for d in json.load(open(sys.argv[1]))) else 0)' "$DEVICES" "$1"
}

cleanup() {
  local status=$?
  # Unpair this run's device (Critter only lets the debug URL revoke a critter-bridge-client one).
  local device; device="$(cat "$WORK/device" 2>/dev/null)"
  if [ -n "$device" ]; then
    open -g "critter://debug-bridge-revoke?deviceId=$device"
    if wait_for 10 unpaired "$device"; then
      echo "unpaired $device"
    else
      echo "could not unpair $device: remove it under Critter's paired phones"
      status=1
    fi
  fi
  rm -rf "$WORK"
  if [ "$TURNED_ON" = 1 ]; then open -g "critter://debug-set?bridgeEnabled=0"; fi
  exit "$status"
}
trap cleanup EXIT

[ "$(defaults read "$DOMAIN" debugEnabled 2>/dev/null)" = 1 ] || { echo "needs: defaults write $DOMAIN debugEnabled -bool true"; exit 2; }
pgrep -x Critter >/dev/null || { echo "Critter is not running"; exit 2; }

if [ "$PREV_BRIDGE" != 1 ]; then
  open -g "critter://debug-set?bridgeEnabled=1"
  TURNED_ON=1
  sleep 2
fi
# A fresh device for this run (the pairing code is approved without asking).
open -g "critter://debug-bridge-pair?out=$WORK/pair.json"
wait_for 20 test -s "$WORK/pair.json" || { echo "could not get a pairing URI"; exit 2; }
URI="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["uri"])' "$WORK/pair.json")"
rm -f "$WORK/pair.json"

cd "$REPO" || exit 2
CRITTER_LIVE_URI="$URI" CRITTER_LIVE_OUT="$WORK/device" swift test --filter LiveBridgeTests 2>&1 | tee "$WORK/test.log"
[ "${PIPESTATUS[0]}" = 0 ] || exit 1
# A skipped test passes too: make sure it ran.
perl -pe 's/\e\[[0-9;]*m//g' "$WORK/test.log" | grep -q 'pairsConnectsAndGetsASnapshotFromTheRealMac() passed' \
  || { echo "LiveBridgeTests did not run"; exit 1; }
