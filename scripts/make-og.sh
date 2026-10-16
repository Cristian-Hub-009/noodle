#!/bin/bash
# Renders scripts/og-card.html to site/og.png (1200×630, the link-preview image) with headless Chrome.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
OUT="$ROOT/site/og.png"

"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --allow-file-access-from-files --window-size=1200,630 --screenshot="$OUT" \
  "file://$ROOT/scripts/og-card.html" >/dev/null 2>&1
sips -g pixelWidth -g pixelHeight "$OUT" | tail -2
echo "$OUT"
