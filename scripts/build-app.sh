#!/bin/bash
# Builds app/build/Noodle.app (release, ad-hoc signed). Prints the bundle path.
# Env: CONFIG=debug|release (default release), OUT=<dir> (default app/build)
#      ARCHS="arm64 x86_64"  universal build (needs full Xcode; default is this Mac's arch)
#      VERSION=0.2.0         stamps CFBundleShortVersionString in the built bundle
#      SIGN_IDENTITY="Developer ID Application: …"  signs with the hardened runtime, a secure
#                            timestamp and app/Noodle.entitlements, ready to notarize (default ad-hoc)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/app"
CONFIG="${CONFIG:-release}"
OUT="${OUT:-$PKG/build}"
APP="$OUT/Noodle.app"

ARCH_FLAGS=()
for a in ${ARCHS:-}; do ARCH_FLAGS+=(--arch "$a"); done
# ${x[@]+...} keeps bash 3.2 happy under set -u when the array is empty
swift build -c "$CONFIG" --package-path "$PKG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} >&2
BIN="$(swift build -c "$CONFIG" --package-path "$PKG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/ClaudePosture"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN" "$APP/Contents/MacOS/ClaudePosture"
cp "$PKG/Info.plist" "$APP/Contents/Info.plist"
rsync -a --exclude '.DS_Store' "$PKG/Resources/" "$APP/Contents/Resources/"
# The `noodle` CLI (hook setup for release and Homebrew installs) rides along inside the bundle.
cp "$ROOT/scripts/noodle" "$ROOT/scripts/_hooks.sh" "$APP/Contents/Resources/bin/"

if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
plutil -lint -s "$APP/Contents/Info.plist"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --entitlements "$PKG/Noodle.entitlements" \
    --sign "$SIGN_IDENTITY" "$APP" >&2
  codesign --verify --strict "$APP" >&2
else
  codesign --force --sign - --timestamp=none "$APP" >&2
fi
echo "$APP"
