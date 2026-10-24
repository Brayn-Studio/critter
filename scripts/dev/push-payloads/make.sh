#!/usr/bin/env bash
# Writes `xcrun simctl push` files for the iOS app: the pushes the Mac would send, sealed with a fixed TEST key, for
# the sessions and requests of the app's `home-mixed` fixture (`ios/Critter/Debug/Fixtures/home-mixed.json`).
# One per notification category, one whose sealed text is broken, one about a request the fixture does not list
# (a banner even in the foreground), and a withdrawal -- which `xcrun simctl push` refuses (error 1401: a background
# push has no user-visible content); the app's `-critterWithdrawPush req-perm-1,done:s-notes` sends the same through
# its handler. Nothing is sent anywhere and nothing connects to a Mac: `critter-bridge-client push-payload` seals with
# the same `PushPayload` / `PushCrypto` as the Mac.
#
#   scripts/dev/push-payloads/make.sh [out dir]        # default ios/build/push-payloads
#   xcrun simctl launch <device> com.braynlabs.critter -critterFixture home-mixed -critterTestPushKey "$KEY"
#   xcrun simctl push <device> com.braynlabs.critter ios/build/push-payloads/permission.apns
#
# `-critterTestPushKey` (DEBUG simulator builds) puts the same test key into the shared keychain, where the
# notification service extension reads it, for that run only: a launch without it replaces it. The key is printed at
# the end. It is the protocol doc's public test key: never the key of a real phone.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="${1:-$REPO/ios/build/push-payloads}"
# The protocol doc's test vector key (bytes 0...31): public, so nothing sealed with it is secret.
KEY="AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

cd "$REPO"
swift build --product critter-bridge-client >/dev/null
CLIENT="$(swift build --show-bin-path)/critter-bridge-client"
mkdir -p "$OUT"

push() {
  local file="$1"
  shift
  "$CLIENT" push-payload --key "$KEY" "$@" > "$OUT/$file.apns"
  echo "$OUT/$file.apns"
}

# Requests the fixture lists (answered or opened by request id).
push permission --category permission --session s-clawd --request req-perm-1 \
  --title "clawd 想 运行 swift test" --subtitle "clawd · main · 终端" --body "swift test --filter BridgeStoreTests"
push question --category question --session s-docs --request req-ask-1 \
  --title "docs-site 问：首页用哪种布局？" --subtitle "docs-site · main · 终端" --body "docs-site"
# Requests it does not list: a banner even with the app in front; their cards say the computer has them.
push permissionNoReason --category permissionNoReason --session codex-api --request req-codex-9 \
  --title "api-server 想 运行 npm test" --subtitle "api-server · Codex" --body "npm test"
push plan --category plan --session s-critter-ios --request req-plan-9 \
  --title "critter-ios 的计划等你批准" --subtitle "critter-ios · main · 终端" --body "critter-ios"
push new-request --category permission --session s-clawd --request req-perm-9 \
  --title "clawd 想 编辑 Package.swift" --subtitle "clawd · main · 终端" --body "/Users/me/clawd/Package.swift"
# Sessions.
push waitingElsewhere --category waitingElsewhere --session codex-landing \
  --title "landing-page 等你确认（请在电脑上处理）" --subtitle "landing-page · Codex · Desktop" --body "landing-page"
push done --category done --session s-notes --title "notes 做完了" --subtitle "notes · 终端" --body "整理好了周报"
push error --category error --session s-critter-ios --title "critter-ios 出错" --subtitle "critter-ios · main · 终端" \
  --body "Build failed"
push test --category test --session test --title "Critter 推送测试" --body "能看到这条，说明推送通了"
# A sealed text that does not open: the plain "Critter / 有会话需要你", and on a phone only 「打开」 (the extension's
# open-only category; this simulator does not run the extension, so it shows the push's own buttons).
push bad --category permission --session s-clawd --request req-perm-1 --title "clawd 想 运行 rm -rf" --corrupt
# Takes the permission request's and the done session's notifications down. Not for `simctl push` (it refuses it,
# 1401): `-critterWithdrawPush req-perm-1,done:s-notes` instead.
"$CLIENT" push-payload --withdraw req-perm-1,done:s-notes > "$OUT/withdraw.apns"
echo "$OUT/withdraw.apns"

echo "test key: -critterTestPushKey $KEY"
