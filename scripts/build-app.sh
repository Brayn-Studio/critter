#!/usr/bin/env bash
# Builds the release binary and assembles dist/Critter.app: a minimal, ad-hoc-signed
# LSUIElement app bundle with no Dock icon. Idempotent -- safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build -c release --product Critter

APP="$ROOT/dist/Critter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Skins" "$APP/Contents/Resources/Sounds"

cp "$ROOT/.build/release/Critter" "$APP/Contents/MacOS/Critter"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT/Skins/." "$APP/Contents/Resources/Skins/"
cp -R "$ROOT/Sounds/." "$APP/Contents/Resources/Sounds/"

codesign --force --sign - "$APP"

echo "Built $APP"
