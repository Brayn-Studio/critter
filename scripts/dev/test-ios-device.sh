#!/usr/bin/env bash
# Checks `scripts/ios-device.sh profiles` against made-up provisioning profiles: plain property lists in a temporary
# folder (CRITTER_PROFILE_DIRS) and a stand-in `security` that prints them, so nothing on this Mac is read or changed.
#
#   scripts/dev/test-ios-device.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/security" <<'SH'
#!/bin/sh
# `security cms -D -i <file>`: the made-up profiles are not signed, so the "decoded" message is the file itself.
[ "$1" = cms ] && [ "$2" = -D ] && [ "$3" = -i ] && exec cat "$4"
exit 1
SH
chmod +x "$WORK/bin/security"

# make <folder> <app|notify|widgets> <hand|xcode> [aps-environment]: one profile for that target with every
# entitlement its ios/Config/*.entitlements asks for.
make_profile() {
  python3 -I - "$REPO/ios/Config" "$@" <<'PY'
import datetime, os, plistlib, sys, uuid

config, folder, target, kind = sys.argv[1:5]
aps = sys.argv[5] if len(sys.argv) > 5 else "development"
bundle, entitlements = {
    "app": ("com.braynlabs.critter", "Critter.entitlements"),
    "notify": ("com.braynlabs.critter.notify", "CritterNotify.entitlements"),
    "widgets": ("com.braynlabs.critter.widgets", "CritterWidgets.entitlements"),
}[target]
with open(os.path.join(config, entitlements), "rb") as f:
    wanted = plistlib.load(f)
granted = {"application-identifier": f"XB89283VYM.{bundle}"}
for key, value in wanted.items():
    granted[key] = aps if key == "aps-environment" else value
profile = {
    "Name": f"{kind} {bundle}",
    "UUID": str(uuid.uuid4()),
    "ExpirationDate": datetime.datetime.now() + datetime.timedelta(days=30),
    "Entitlements": granted,
}
if kind == "xcode":
    profile["IsXcodeManaged"] = True
os.makedirs(folder, exist_ok=True)
with open(os.path.join(folder, f"{target}-{kind}-{profile['UUID']}.mobileprovision"), "wb") as f:
    plistlib.dump(profile, f)
PY
}

failures=0
# check <name> <folder> <expected exit> <expected stdout: exactly one line, all of it matching (grep -Ex); empty: no
# stdout at all>. Whatever `profiles` prints goes to xcodebuild's command line, so one more word or line must fail.
check() {
  local name="$1" folder="$2" want_status="$3" want_out="$4" out status=0 ok=0
  out="$(PATH="$WORK/bin:$PATH" CRITTER_PROFILE_DIRS="$folder" "$REPO/scripts/ios-device.sh" profiles 2>"$WORK/err")" || status=$?
  if [ -z "$want_out" ]; then
    [ -z "$out" ] && ok=1
  elif [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] && printf '%s\n' "$out" | grep -Eqx "$want_out"; then
    ok=1
  fi
  if [ "$status" = "$want_status" ] && [ "$ok" = 1 ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: exit $status, stdout \"$out\""
    sed 's/^/     /' "$WORK/err"
    failures=$((failures + 1))
  fi
}

for t in app notify widgets; do make_profile "$WORK/hand" "$t" hand; done
hand_out='CRITTER_PROFILE_APP=[0-9a-f-]+ CRITTER_PROFILE_NOTIFY=[0-9a-f-]+ CRITTER_PROFILE_WIDGETS=[0-9a-f-]+'
check "profiles made by hand are named by uuid" "$WORK/hand" 0 "$hand_out"

for t in app notify widgets; do make_profile "$WORK/xcode" "$t" xcode; done
check "profiles Xcode made sign automatically" "$WORK/xcode" 0 'CODE_SIGN_STYLE=Automatic'

for t in app notify widgets; do make_profile "$WORK/both" "$t" hand; make_profile "$WORK/both" "$t" xcode; done
check "with both kinds for every target, the ones made by hand win" "$WORK/both" 0 "$hand_out"

make_profile "$WORK/mixed" app hand
make_profile "$WORK/mixed" notify xcode
make_profile "$WORK/mixed" widgets xcode
check "a mix of the two kinds is refused" "$WORK/mixed" 1 ""
grep -q "not every target has a profile of the same kind" "$WORK/err" || { echo "FAIL the mix is not explained"; failures=$((failures + 1)); }
grep -q "one build signs them all the same way" "$WORK/err" || { echo "FAIL the mix is not explained"; failures=$((failures + 1)); }

# A target with both kinds is no "only": no single kind is on all three, and the message is still true.
make_profile "$WORK/mixed-both" app hand
make_profile "$WORK/mixed-both" app xcode
make_profile "$WORK/mixed-both" notify xcode
make_profile "$WORK/mixed-both" widgets hand
check "a mix where one target has both kinds is refused" "$WORK/mixed-both" 1 ""
grep -q "not every target has a profile of the same kind" "$WORK/err" || { echo "FAIL the mix is not explained"; failures=$((failures + 1)); }

make_profile "$WORK/production" app xcode production
make_profile "$WORK/production" notify xcode
make_profile "$WORK/production" widgets xcode
check "a production push profile is refused" "$WORK/production" 1 ""

[ "$failures" = 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
