#!/usr/bin/env bash
# Renders the phone mockups (docs/superpowers/specs/2026-10-19-critter-phone-visual-mockups.html) to PNG tiles, to
# compare a screen of the iOS app with: headless Chrome takes the whole page at 1400 px wide (a screenshot of an
# anchor such as #home comes out blank, so it is always the whole page), then Pillow cuts it into 1400 x 1500
# tiles, mockup-01.png, mockup-02.png, … from the top. The full page is kept as mockups-full.png.
#
#   scripts/dev/render-mockups.sh [output directory]      # default: ios/build/mockups
#
# Needs Google Chrome in /Applications and python3 with Pillow. Nothing here touches a window: Chrome runs headless
# with a throwaway profile.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$REPO/ios/build/mockups}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PAGE="$REPO/docs/superpowers/specs/2026-10-19-critter-phone-visual-mockups.html"
WIDTH=1400
# The page is about 18500 px tall; the window is a little taller, and the blank rows under the page are cut off.
HEIGHT=19000
TILE=1500

[ -x "$CHROME" ] || { echo "Google Chrome is not in /Applications" >&2; exit 1; }
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
PROFILE="$(mktemp -d "${TMPDIR:-/tmp}/critter-mockups.XXXXXX")"
trap 'rm -rf "$PROFILE"' EXIT

FULL="$OUT/mockups-full.png"
rm -f "$FULL" "$OUT"/mockup-*.png
# The pets on the page are drawn by its script from Skins/*/manifest.json: the virtual time budget lets them settle.
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --virtual-time-budget=3000 \
    --window-size="$WIDTH,$HEIGHT" --user-data-dir="$PROFILE" --screenshot="$FULL" "file://$PAGE" >/dev/null 2>&1
[ -s "$FULL" ] || { echo "Chrome did not write $FULL" >&2; exit 1; }

# Cut into tiles with Pillow (`sips --cropOffset` crops around the center whatever the offset says), stopping where
# the page does: the rows at the bottom that are only the page's background are left out.
python3 - "$FULL" "$OUT" "$TILE" <<'PY'
import os
import sys
from PIL import Image

full, out, tile = sys.argv[1], sys.argv[2], int(sys.argv[3])
im = Image.open(full).convert('RGB')
w, h = im.size
bg = im.getpixel((w - 1, h - 1))
bottom = h
while bottom > 0:
    colors = im.crop((0, bottom - 1, w, bottom)).getcolors(w)
    if not (colors and len(colors) == 1 and colors[0][1] == bg):
        break
    bottom -= 1
n = 0
for top in range(0, bottom, tile):
    n += 1
    im.crop((0, top, w, min(top + tile, bottom))).save(os.path.join(out, 'mockup-%02d.png' % n))
print(f'{n} tiles in {out} (page {bottom} px tall)')
PY
