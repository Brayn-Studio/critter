#!/usr/bin/env bash
# What `make ios` and `make ios-install` need from this Mac before they touch anything. Only reads: nothing is
# registered with the developer account, nothing is installed.
#
#   scripts/ios-device.sh profiles   # the installed provisioning profile for the app and each extension, as
#                                    # xcodebuild settings: CRITTER_PROFILE_APP=<uuid> CRITTER_PROFILE_NOTIFY=<uuid>
#                                    # CRITTER_PROFILE_WIDGETS=<uuid> for profiles made by hand, CODE_SIGN_STYLE=Automatic
#                                    # when they are the ones Xcode made (see below); exits 1, saying what is missing,
#                                    # if one is not there
#   scripts/ios-device.sh iphone     # the identifier of the one iPhone connected to this Mac; exits 1 if there is
#                                    # none or more than one
#
# A profile counts when it is for this team's explicit App ID (`<team>.<bundle id>`), has not expired, and carries
# every entitlement the target's `ios/Config/*.entitlements` asks for (the App Group by name; push with the value
# `development`, as the build run from Xcode gets its token from the development APNs). Looked for where Xcode
# keeps them: ~/Library/Developer/Xcode/UserData/Provisioning Profiles and ~/Library/MobileDevice/Provisioning
# Profiles (CRITTER_PROFILE_DIRS, colon-separated, instead).
#
# Profiles Xcode made itself (`ALLOW_PROVISIONING=1 make ios`, or Xcode's automatic signing) can only be used by
# automatic signing. When every target has one, the build signs automatically but without -allowProvisioningUpdates,
# so Xcode takes the profiles already on this Mac and never asks the developer account for anything. Profiles made by
# hand win when every target has one of those; a mix of the two kinds is refused.
#
# An iPhone counts when it is a real one (not a simulator), paired with this Mac, and reachable (connected, or
# available over the cable or the network: devicectl connects to it to install). CRITTER_DEVICES_JSON names a
# `devicectl list devices --json-output` file to read instead of asking devicectl.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Temporary files, removed however the script ends: an EXIT trap runs also when `set -e` stops it at a failing step
# (a RETURN trap in the functions would not), and on Ctrl-C or a TERM (turned into an exit).
DECODED_DIR=""
DEVICES_FILE=""
cleanup() {
  [ -z "$DECODED_DIR" ] || rm -rf "$DECODED_DIR"
  [ -z "$DEVICES_FILE" ] || rm -f "$DEVICES_FILE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

profiles() {
  local team
  team="$(sed -n 's/^DEVELOPMENT_TEAM = //p' "$REPO/ios/Config/Base.xcconfig")"
  local dirs="${CRITTER_PROFILE_DIRS:-$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles:$HOME/Library/MobileDevice/Provisioning Profiles}"
  local decoded
  decoded="$(mktemp -d)"
  DECODED_DIR="$decoded"
  local IFS=:
  local n=0
  for dir in $dirs; do
    [ -d "$dir" ] || continue
    for file in "$dir"/*.mobileprovision "$dir"/*.provisionprofile; do
      [ -f "$file" ] || continue
      n=$((n + 1))
      # The profile is a signed CMS message around a property list.
      security cms -D -i "$file" > "$decoded/$n.plist" 2>/dev/null || rm -f "$decoded/$n.plist"
    done
  done
  unset IFS
  python3 -I - "$team" "$REPO/ios/Config" "$decoded" <<'PY'
import datetime, glob, os, plistlib, sys

team, config, decoded = sys.argv[1:4]
targets = [
    ("CRITTER_PROFILE_APP", "com.braynlabs.critter", "Critter.entitlements"),
    ("CRITTER_PROFILE_NOTIFY", "com.braynlabs.critter.notify", "CritterNotify.entitlements"),
    ("CRITTER_PROFILE_WIDGETS", "com.braynlabs.critter.widgets", "CritterWidgets.entitlements"),
]
profiles = []
for path in sorted(glob.glob(os.path.join(decoded, "*.plist"))):
    try:
        with open(path, "rb") as f:
            profiles.append(plistlib.load(f))
    except Exception:
        pass
now = datetime.datetime.now(datetime.timezone.utc)

def expires(p):
    date = p.get("ExpirationDate")
    if date is None:
        return now
    return date if date.tzinfo else date.replace(tzinfo=datetime.timezone.utc)

def missing(p, wanted):
    """The entitlements `wanted` asks for that profile `p` does not carry (or carries with another value)."""
    have = p.get("Entitlements", {})
    gaps = []
    for key, value in wanted.items():
        if key not in have:
            gaps.append(key)
        elif key == "com.apple.security.application-groups":
            gaps += [g for g in value if g not in have[key]]
        elif key == "aps-environment" and have[key] != value:
            # A profile made for the App Store or TestFlight has "production"; a build run from Xcode on a phone gets
            # its pushes from the development APNs, and that is what the token would be for.
            gaps.append(f'aps-environment "{value}" (this profile has "{have[key]}")')
    return gaps

def describe(bundle, p):
    managed = " (Xcode managed)" if p.get("IsXcodeManaged") else ""
    return f"{bundle}: {p.get('Name', '?')}{managed} ({p['UUID']}, until {expires(p):%Y-%m-%d})"

chosen, problems = [], []
for variable, bundle, entitlements in targets:
    with open(os.path.join(config, entitlements), "rb") as f:
        wanted = plistlib.load(f)
    app_id = f"{team}.{bundle}"
    mine = [p for p in profiles if p.get("Entitlements", {}).get("application-identifier") == app_id]
    good = [p for p in mine if expires(p) > now and not missing(p, wanted)]
    if good:
        by_hand = [p for p in good if not p.get("IsXcodeManaged")]
        by_xcode = [p for p in good if p.get("IsXcodeManaged")]
        chosen.append((variable, bundle,
                       max(by_hand, key=expires) if by_hand else None,
                       max(by_xcode, key=expires) if by_xcode else None))
    elif not mine:
        problems.append(f"{bundle}: no provisioning profile for {app_id}")
    else:
        newest = max(mine, key=expires)
        why = "is expired" if expires(newest) <= now else "lacks " + ", ".join(missing(newest, wanted))
        problems.append(f"{bundle}: profile \"{newest.get('Name', '?')}\" {why}")
if problems:
    print("make ios: the provisioning profiles are not all there:", file=sys.stderr)
    for line in problems:
        print("  " + line, file=sys.stderr)
    print("先把能力和描述文件备好：在开发者账号里给 App ID 打开能力、生成描述文件、装进 Xcode（README「装到 iPhone 上」）。"
          "或者经账号主人同意，这一次用 ALLOW_PROVISIONING=1 make ios 让 Xcode 自己登记。", file=sys.stderr)
    sys.exit(1)
if all(by_hand for _, _, by_hand, _ in chosen):
    for _, bundle, p, _ in chosen:
        print(describe(bundle, p), file=sys.stderr)
    print(" ".join(f"{variable}={p['UUID']}" for variable, _, p, _ in chosen))
elif all(by_xcode for _, _, _, by_xcode in chosen):
    # Manual signing refuses a profile Xcode manages; automatic signing without -allowProvisioningUpdates only picks
    # among the profiles already installed.
    for _, bundle, _, p in chosen:
        print(describe(bundle, p), file=sys.stderr)
    print("CODE_SIGN_STYLE=Automatic")
else:
    print("make ios: not every target has a profile of the same kind (made by hand, or made by Xcode); one build signs "
          "them all the same way:", file=sys.stderr)
    for _, bundle, by_hand, by_xcode in chosen:
        print("  " + describe(bundle, by_hand or by_xcode), file=sys.stderr)
    print("把三份描述文件统一成同一种：都在开发者网站手动生成，或者经账号主人同意用 ALLOW_PROVISIONING=1 make ios "
          "让 Xcode 全部重新生成。", file=sys.stderr)
    sys.exit(1)
PY
}

iphone() {
  local json
  if [ -n "${CRITTER_DEVICES_JSON:-}" ]; then
    json="$CRITTER_DEVICES_JSON"
  else
    json="$(mktemp)"
    DEVICES_FILE="$json"
    xcrun devicectl list devices --quiet --json-output "$json" >/dev/null
  fi
  python3 -I - "$json" <<'PY'
import json, sys

with open(sys.argv[1]) as f:
    devices = json.load(f).get("result", {}).get("devices", [])

def field(device, new, old):
    """`properties` (devicectl's current fields), else the older field it replaced."""
    value = device.get("properties", {})
    for key in new:
        value = value.get(key, {}) if isinstance(value, dict) else {}
    if value not in ({}, None):
        return value
    value = device
    for key in old:
        value = value.get(key, {}) if isinstance(value, dict) else {}
    return None if value == {} else value

phones = []
for d in devices:
    reality = field(d, ["hardware", "reality"], ["hardwareProperties", "reality"])
    kind = field(d, ["hardware", "deviceType"], ["hardwareProperties", "deviceType"])
    paired = field(d, ["connection", "pairingState"], ["connectionProperties", "pairingState"])
    state = field(d, ["connection", "state"], ["connectionProperties", "tunnelState"])
    if reality == "simulated" or kind != "iPhone" or paired != "paired" or state == "unavailable":
        continue
    name = field(d, ["device", "name"], ["deviceProperties", "name"]) or "?"
    phones.append((d.get("identifier", "?"), name, state))
if len(phones) == 1:
    identifier, name, state = phones[0]
    print(f"iPhone: {name} ({identifier}, {state})", file=sys.stderr)
    print(identifier)
elif not phones:
    print("make ios-install: no iPhone is connected to this Mac. Connect it with a cable (or put it on the same "
          "Wi-Fi after pairing it once in Xcode), unlock it, trust this Mac, and turn on Developer Mode "
          "(Settings › Privacy & Security). `xcrun devicectl list devices` shows what this Mac sees.", file=sys.stderr)
    sys.exit(1)
else:
    print("make ios-install: more than one iPhone is connected; leave one:", file=sys.stderr)
    for identifier, name, state in phones:
        print(f"  {name} ({identifier}, {state})", file=sys.stderr)
    sys.exit(1)
PY
}

case "${1:-}" in
  profiles) profiles ;;
  iphone) iphone ;;
  *)
    echo "usage: $0 profiles|iphone" >&2
    exit 2
    ;;
esac
