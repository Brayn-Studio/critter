#!/usr/bin/env bash
# Builds the release binary and assembles dist/Clawd.app: a minimal, ad-hoc-signed
# LSUIElement app bundle with no Dock icon. Idempotent -- safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build -c release --product Clawd

APP="$ROOT/dist/Clawd.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Skins"

cp "$ROOT/.build/release/Clawd" "$APP/Contents/MacOS/Clawd"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT/Skins/." "$APP/Contents/Resources/Skins/"

codesign --force --sign - "$APP"

echo "Built $APP"
