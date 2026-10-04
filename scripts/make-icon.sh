#!/bin/bash
# Draws Toni waving on a warm tile and writes app/Resources/Noodle.icns.
# Needs Google Chrome (headless, to render the SVG) plus sips and iconutil, which ship with macOS.
#   scripts/make-icon.sh [character]    character is a folder under app/Resources/figures, default rigatoni
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHARACTER="${1:-rigatoni}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
SRC="$ROOT/app/Resources/figures/$CHARACTER/wave.svg"
OUT="$ROOT/app/Resources/Noodle.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[[ -x "$CHROME" ]] || { echo "Chrome not found at $CHROME (set CHROME=...)" >&2; exit 1; }
[[ -f "$SRC" ]] || { echo "No $SRC" >&2; exit 1; }

# The SVG without its fixed size, so it can scale to the tile.
SVG="$(sed -E 's/ width="96" height="96"//' "$SRC")"
cat > "$WORK/icon.html" <<HTML
<!doctype html><meta charset="utf-8">
<style>
  html, body { margin: 0; width: 1024px; height: 1024px; background: transparent; overflow: hidden; }
  .tile {
    position: absolute; left: 100px; top: 100px; width: 824px; height: 824px; border-radius: 186px;
    background: linear-gradient(160deg, #FFF8EC 0%, #FBEBD2 100%);
    box-shadow: 0 22px 44px rgba(43, 36, 32, .28), 0 0 0 2px rgba(43, 36, 32, .06) inset, 0 -10px 30px rgba(255, 255, 255, .55) inset;
    display: grid; place-items: center;
  }
  .tile svg { width: 700px; height: 700px; display: block; overflow: visible; margin-top: 14px; }
</style>
<div class="tile">$SVG</div>
HTML

"$CHROME" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
  --force-device-scale-factor=1 --window-size=1024,1024 --virtual-time-budget=2000 \
  --screenshot="$WORK/icon-1024.png" "file://$WORK/icon.html" >/dev/null 2>&1

SET="$WORK/Noodle.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon-1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$WORK/icon-1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$OUT"
cp "$WORK/icon-1024.png" "${PREVIEW:-/dev/null}" 2>/dev/null || true
echo "Wrote $OUT"
