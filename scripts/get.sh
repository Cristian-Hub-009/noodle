#!/bin/bash
# One-line install of the latest release, no Xcode needed:
#   curl -fsSL https://raw.githubusercontent.com/pcybriwsky/noodle/main/scripts/get.sh | bash
# Downloads Noodle.zip, checks its sha256, puts Noodle.app in ~/Applications, then runs
# `noodle setup` (shows the settings.json diff and asks first, same as install.sh).
#   ... | bash -s -- -y     answer yes to every prompt
#   NOODLE_VERSION=0.2.0    pin a release (default latest)
#   APP_DIR=...             install location (default ~/Applications)
set -euo pipefail
REPO=pcybriwsky/noodle
APP_DIR="${APP_DIR:-$HOME/Applications}"
APP="$APP_DIR/Noodle.app"
LEGACY="$APP_DIR/ClaudePosture.app"   # pre-rename install
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

die() { echo "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || die "Noodle is macOS only."
command -v jq >/dev/null || die "Noodle needs jq to edit ~/.claude/settings.json. Install it (brew install jq) and run this again."

if [[ -n "${NOODLE_BASE_URL:-}" ]]; then BASE="$NOODLE_BASE_URL"
elif [[ -n "${NOODLE_VERSION:-}" ]]; then BASE="https://github.com/$REPO/releases/download/v${NOODLE_VERSION#v}"
else BASE="https://github.com/$REPO/releases/latest/download"; fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading Noodle..."
curl -fsSL "$BASE/Noodle.zip" -o "$TMP/Noodle.zip"
curl -fsSL "$BASE/Noodle.zip.sha256" -o "$TMP/Noodle.zip.sha256"
(cd "$TMP" && shasum -a 256 -c Noodle.zip.sha256 >/dev/null) || die "Checksum mismatch, not installing."
ditto -x -k "$TMP/Noodle.zip" "$TMP/unzipped"
[[ -d "$TMP/unzipped/Noodle.app" ]] || die "Noodle.zip didn't contain Noodle.app."

pkill -x ClaudePosture 2>/dev/null || true
mkdir -p "$APP_DIR"
if [[ -d "$LEGACY" ]]; then "$LSREGISTER" -u "$LEGACY" 2>/dev/null || true; rm -rf "$LEGACY"; fi
rm -rf "$APP"
ditto "$TMP/unzipped/Noodle.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true   # ad-hoc signed, not notarized
echo "Installed $APP ($("$APP/Contents/Resources/bin/noodle" version))"

"$APP/Contents/Resources/bin/noodle" setup "$@"
echo "Later: $APP/Contents/Resources/bin/noodle remove  (disconnects from Claude Code)"
