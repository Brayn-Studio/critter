#!/usr/bin/env bash
# What `make ios` and `make ios-install` need from this Mac before they touch anything. Only reads: nothing is
# registered with the developer account, nothing is installed.
#
#   scripts/ios-device.sh profiles   # the installed provisioning profile for the app and each extension, as
#                                    # CRITTER_PROFILE_APP=<uuid> CRITTER_PROFILE_NOTIFY=<uuid> CRITTER_PROFILE_WIDGETS=<uuid>
#                                    # (xcodebuild settings); exits 1, saying what is missing, if one is not there
#   scripts/ios-device.sh iphone     # the identifier of the one iPhone connected to this Mac; exits 1 if there is
#                                    # none or more than one
#
# A profile counts when it is for this team's explicit App ID (`<team>.<bundle id>`), has not expired, and carries
# every entitlement the target's `ios/Config/*.entitlements` asks for (the App Group by name). Looked for where Xcode
# keeps them: ~/Library/Developer/Xcode/UserData/Provisioning Profiles and ~/Library/MobileDevice/Provisioning
# Profiles (CRITTER_PROFILE_DIRS, colon-separated, instead).
#
# An iPhone counts when it is a real one (not a simulator), paired with this Mac, and reachable (connected, or
# available over the cable or the network: devicectl connects to it to install). CRITTER_DEVICES_JSON names a
# `devicectl list devices --json-output` file to read instead of asking devicectl.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

profiles() {
  local team
  team="$(sed -n 's/^DEVELOPMENT_TEAM = //p' "$REPO/ios/Config/Base.xcconfig")"
  local dirs="${CRITTER_PROFILE_DIRS:-$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles:$HOME/Library/MobileDevice/Provisioning Profiles}"
  local decoded
  decoded="$(mktemp -d)"
  trap 'rm -rf "$decoded"' RETURN
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
    """The entitlements `wanted` asks for that profile `p` does not carry."""
    have = p.get("Entitlements", {})
    gaps = []
    for key, value in wanted.items():
        if key not in have:
            gaps.append(key)
        elif key == "com.apple.security.application-groups":
            gaps += [g for g in value if g not in have[key]]
    return gaps

found, problems = [], []
for variable, bundle, entitlements in targets:
    with open(os.path.join(config, entitlements), "rb") as f:
        wanted = plistlib.load(f)
    app_id = f"{team}.{bundle}"
    mine = [p for p in profiles if p.get("Entitlements", {}).get("application-identifier") == app_id]
    good = [p for p in mine if expires(p) > now and not missing(p, wanted)]
    if good:
        best = max(good, key=expires)
        found.append(f"{variable}={best['UUID']}")
        print(f"{bundle}: {best.get('Name', '?')} ({best['UUID']}, until {expires(best):%Y-%m-%d})", file=sys.stderr)
    elif not mine:
        problems.append(f"{bundle}: no provisioning profile for {app_id}")
    else:
        newest = max(mine, key=expires)
        why = "expired" if expires(newest) <= now else "missing " + ", ".join(missing(newest, wanted))
        problems.append(f"{bundle}: profile \"{newest.get('Name', '?')}\" is {why}")
if problems:
    print("make ios: the provisioning profiles are not all there:", file=sys.stderr)
    for line in problems:
        print("  " + line, file=sys.stderr)
    print("先把能力和描述文件备好：在开发者账号里给 App ID 打开能力、生成描述文件、装进 Xcode（README「装到 iPhone 上」）。"
          "或者经账号主人同意，这一次用 ALLOW_PROVISIONING=1 make ios 让 Xcode 自己登记。", file=sys.stderr)
    sys.exit(1)
print(" ".join(found))
PY
}

iphone() {
  local json
  if [ -n "${CRITTER_DEVICES_JSON:-}" ]; then
    json="$CRITTER_DEVICES_JSON"
  else
    json="$(mktemp)"
    trap 'rm -f "$json"' RETURN
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
