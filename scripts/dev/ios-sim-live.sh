#!/usr/bin/env bash
# Runs the iOS app in the simulator against the REAL Critter on this Mac and takes two screenshots:
# `make ios-sim`, a throwaway `critter-bridge-client` device paired from the command line
# (`-critterPairURI`), 10 s later `home.png`; then the app is stopped and started again without arguments
# (the pairing and the token must have been kept), 5 s later `relaunch.png`. Both should show "已连接" and the
# sessions the Mac has. The device is unpaired again at the end.
#
# The app only reads: nothing is sent to your sessions (no seen, say, interrupt or answer). Only the simulator's
# command line (`xcrun simctl`) is used; nothing drives a window.
#
# Prerequisites: Critter is running, `defaults write local.critter.pet debugEnabled -bool true`.
# It turns the phone bridge on for the run if it was off, and back off afterwards.
#
#   scripts/dev/ios-sim-live.sh
#
# Environment: OUT (where the screenshots go; default ios/build/live), SIM_UDID (default: the iPhone 17 Pro with the
# newest iOS, as `make ios-sim` picks it).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOMAIN=local.critter.pet
BUNDLE=com.braynlabs.critter
APP="$REPO/ios/build/Build/Products/Debug-iphonesimulator/Critter.app"
OUT="${OUT:-$REPO/ios/build/live}"
# The user's own temp directory: Critter only writes the pairing file under it (or ~/.critter).
TMPROOT="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "${TMPDIR:-/tmp}/")"
WORK="$(mktemp -d "${TMPROOT%/}/critter-ios-live.XXXXXX")"
DEVICES="${CRITTER_HOME:-$HOME/.critter}/bridge/devices.json"
PREV_BRIDGE="$(defaults read "$DOMAIN" bridgeEnabled 2>/dev/null || echo 0)"
TURNED_ON=0
SIM=""
BEFORE=""

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

# The ids of the `critter-bridge-client` devices the Mac lists, one per line.
bridge_clients() {
  python3 -I -c '
import json, sys
print("\n".join(d["id"] for d in json.load(open(sys.argv[1])) if d.get("name") == "critter-bridge-client"))' "$DEVICES" 2>/dev/null || true
}

# The ones that were not there when the run began.
new_bridge_clients() {
  comm -13 <(printf '%s\n' "$BEFORE" | sort) <(bridge_clients | sort)
}

# The iPhone 17 Pro on the newest iOS runtime.
pick_simulator() {
  xcrun simctl list devices available -j | python3 -I -c '
import json, re, sys
best = None
for runtime, devices in json.load(sys.stdin)["devices"].items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in devices:
        if d["name"] == "iPhone 17 Pro" and d.get("isAvailable", True) and (best is None or version > best[0]):
            best = (version, d["udid"])
print(best[1] if best else "")'
}

cleanup() {
  local status=$?
  # Stop the app first, so it does not notice the pairing going away.
  if [ -n "$SIM" ]; then xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1; fi
  # Unpair this run's devices (Critter only lets the debug URL revoke a critter-bridge-client one): the one the
  # app says it paired, and any the Mac lists that were not there before, in case the app never got to say.
  local ids id
  ids="$(cat "$WORK/device" 2>/dev/null)
$(new_bridge_clients)"
  for id in $(printf '%s\n' "$ids" | sort -u | grep -v '^$'); do
    open -g "critter://debug-bridge-revoke?deviceId=$id"
    if wait_for 10 unpaired "$id"; then
      echo "unpaired $id"
    else
      echo "could not unpair $id: remove it under Critter's paired phones"
      status=1
    fi
  done
  # Leave the simulator with a fresh, unpaired app rather than one that points at a device that is gone.
  if [ -n "$SIM" ]; then
    xcrun simctl uninstall "$SIM" "$BUNDLE" >/dev/null 2>&1
    if [ -d "$APP" ]; then xcrun simctl install "$SIM" "$APP" >/dev/null 2>&1; fi
  fi
  rm -rf "$WORK"
  if [ "$TURNED_ON" = 1 ]; then open -g "critter://debug-set?bridgeEnabled=0"; fi
  exit "$status"
}
trap cleanup EXIT

[ "$(defaults read "$DOMAIN" debugEnabled 2>/dev/null)" = 1 ] || { echo "needs: defaults write $DOMAIN debugEnabled -bool true"; exit 2; }
pgrep -x Critter >/dev/null || { echo "Critter is not running"; exit 2; }
SIM="${SIM_UDID:-$(pick_simulator)}"
[ -n "$SIM" ] || { echo "no iPhone 17 Pro simulator found (set SIM_UDID)"; exit 2; }

cd "$REPO" || exit 2
echo "building (make ios-sim)..."
if ! make ios-sim >"$WORK/build.log" 2>&1 || ! grep -q 'BUILD SUCCEEDED' "$WORK/build.log"; then
  tail -n 30 "$WORK/build.log"
  echo "make ios-sim failed"
  exit 1
fi
echo "BUILD SUCCEEDED"

xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || { echo "could not boot simulator $SIM"; exit 2; }
# A fresh install, so there is no pairing from an earlier run.
xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1
xcrun simctl uninstall "$SIM" "$BUNDLE" >/dev/null 2>&1
xcrun simctl install "$SIM" "$APP" || { echo "could not install the app"; exit 2; }

if [ "$PREV_BRIDGE" != 1 ]; then
  open -g "critter://debug-set?bridgeEnabled=1"
  TURNED_ON=1
  sleep 2
fi
BEFORE="$(bridge_clients)"
# A fresh device for this run (the pairing code is approved without asking).
open -g "critter://debug-bridge-pair?out=$WORK/pair.json"
wait_for 20 test -s "$WORK/pair.json" || { echo "could not get a pairing URI"; exit 2; }
URI="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["uri"])' "$WORK/pair.json")"
rm -f "$WORK/pair.json"

mkdir -p "$OUT"
rm -f "$OUT/home.png" "$OUT/relaunch.png"

# 1. Paired from the command line; the Mac lists it as critter-bridge-client.
xcrun simctl launch "$SIM" "$BUNDLE" -critterPairURI "$URI" -critterDeviceName critter-bridge-client >/dev/null \
  || { echo "could not launch the app"; exit 1; }
sleep 10
xcrun simctl io "$SIM" screenshot "$OUT/home.png" >/dev/null 2>&1 || { echo "could not take a screenshot"; exit 1; }

# 2. Stopped and started again without arguments: still paired, connected again.
xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1
xcrun simctl launch "$SIM" "$BUNDLE" >/dev/null || { echo "could not launch the app again"; exit 1; }
sleep 5
xcrun simctl io "$SIM" screenshot "$OUT/relaunch.png" >/dev/null 2>&1 || { echo "could not take a screenshot"; exit 1; }
xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1

# 3. What the app kept: the pairing (its deviceId is what gets revoked) and the last snapshot, in a folder kept out of
# backups. The app's defaults live in its container (`simctl spawn ... defaults read` does not see them).
DATA="$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)"
SNAPSHOTS="$DATA/Library/Application Support/Snapshot"
DEVICE="$(python3 -I -c '
import json, plistlib, sys
with open(sys.argv[1], "rb") as f:
    prefs = plistlib.load(f)
print(json.loads(prefs["critter.pairing"])["deviceId"])' "$DATA/Library/Preferences/$BUNDLE.plist" 2>/dev/null)"
[ -n "$DEVICE" ] || { echo "the app has no pairing: it did not pair"; exit 1; }
echo "$DEVICE" >"$WORK/device"
SESSIONS="$(python3 -I -c '
import json, sys
print(len(json.load(open(sys.argv[1]))["body"]["sessions"]))' "$SNAPSHOTS/snapshot.json" 2>/dev/null)"
[ -n "$SESSIONS" ] || { echo "the app has no snapshot: it did not connect"; exit 1; }
echo "paired as $DEVICE; the app has a snapshot of $SESSIONS session(s)"
# `isExcludedFromBackup` on the folder is kept as this attribute.
xattr -p com.apple.metadata:com_apple_backup_excludeItem "$SNAPSHOTS" >/dev/null 2>&1 \
  || { echo "the snapshot's folder is not excluded from backup"; exit 1; }
echo "the snapshot's folder is excluded from backup"

echo "screenshots:"
echo "  $OUT/home.png"
echo "  $OUT/relaunch.png"
