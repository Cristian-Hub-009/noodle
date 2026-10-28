#!/bin/bash
# Build and run this checkout in place. No install, sudo, or Claude hook setup.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

fail() {
  printf '\n%s\n' "$1" >&2
  if [[ -t 0 ]]; then read -r -p 'Press Return to close.' _; fi
  exit 1
}

[[ "$(uname -s)" == Darwin ]] || fail 'Noodle needs macOS 13 or newer.'
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$MACOS_MAJOR" -ge 13 ]] || fail 'Noodle needs macOS 13 or newer.'
if ! xcrun --find swift >/dev/null 2>&1; then
  fail 'Building from source needs Apple Command Line Tools (Swift 5.10 or newer). Use the prebuilt GitHub Actions download if you do not want development tools on this Mac.'
fi

printf 'Building Noodle. The first build may take a few minutes.\n'
if ! APP="$(bash "$ROOT/scripts/build-app.sh")"; then
  fail 'Build failed. Read the error above. Swift 5.10 or newer is required.'
fi
open "$APP"
printf '\nNoodle is running. Look for the standing figure in the menu bar.\n'
printf 'New configurations use a 20-minute timer. Choose Show one now to try it.\n'
