#!/bin/bash
# Tests the settings.json merge/unmerge against temp files only: once through install.sh / uninstall.sh (jq),
# then again through the app's Swift version (ClaudeHooks.swift), which must match jq byte for byte.
# Usage: scripts/test-hooks.sh [settings.json to copy as an extra round-trip fixture]
#   SKIP_SWIFT=1   jq only
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/posture-hooks.XXXXXX")"
pass=0; fail=0
FIXTURE="${1:-}"
ok()   { echo "  ok   $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL $1"; fail=$((fail+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run() {
  if [[ $BACKEND == swift ]]; then
    "$T/hooks" "$([[ $2 == install.sh ]] && echo add || echo remove)" "$1" >"$T/out" 2>&1
  else
    CLAUDE_SETTINGS="$1" SKIP_APP=1 "$ROOT/scripts/$2" -y >"$T/out" 2>&1
  fi
}
count() { jq --arg c "$2" '[.. | objects | select(.command? == $c)] | length' "$1"; }
P="open -g 'claudeposture://prompt' >/dev/null 2>&1 &"
S="open -g 'claudeposture://stop' >/dev/null 2>&1 &"
nbak() { ls "$1".bak-* 2>/dev/null | wc -l | tr -d ' '; }

# The cases, run once per backend. Not indented, so the heredoc fixtures stay jq-formatted.
suite() {
BACKEND="$1"; mkdir -p "$T/$BACKEND"
echo "== $BACKEND"
echo "missing file"
F="$T/$BACKEND/missing/settings.json"
run "$F" install.sh
check "created with both hooks" '[[ $(count "$F" "$P") == 1 && $(count "$F" "$S") == 1 ]]'
check "no backup for a new file" '[[ $(nbak "$F") == 0 ]]'
run "$F" uninstall.sh
check "uninstall leaves {}" '[[ $(jq -c . "$F") == "{}" ]]'

echo "other hooks and settings"
F="$T/$BACKEND/other/settings.json"; mkdir -p "$T/$BACKEND/other"
cat > "$F" <<'JSON'
{
  "model": "opus",
  "permissions": {
    "allow": [
      "Bash(git status)"
    ]
  },
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo hi"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "afplay /System/Library/Sounds/Glass.aiff"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "./guard.sh"
          }
        ]
      }
    ]
  }
}
JSON
cp "$F" "$T/$BACKEND/orig.json"
run "$F" install.sh
check "ours added once each" '[[ $(count "$F" "$P") == 1 && $(count "$F" "$S") == 1 ]]'
check "other hooks kept" '[[ $(count "$F" "echo hi") == 1 && $(count "$F" "./guard.sh") == 1 && $(count "$F" "afplay /System/Library/Sounds/Glass.aiff") == 1 ]]'
check "other settings kept" '[[ "$(jq -c "del(.hooks)" "$F")" == "$(jq -c "del(.hooks)" "$T/$BACKEND/orig.json")" ]]'
check "backup created and equals original" '[[ $(nbak "$F") == 1 ]] && cmp -s "$(ls "$F".bak-*)" "$T/$BACKEND/orig.json"'
cp "$F" "$T/$BACKEND/once.json"
sleep 1; run "$F" install.sh
check "second install changes nothing" 'cmp -s "$F" "$T/$BACKEND/once.json"'
check "second install says nothing to add" 'grep -q "nothing to add" "$T/out"'
check "second install makes no backup" '[[ $(nbak "$F") == 1 ]]'
run "$F" uninstall.sh
check "round trip is byte-identical" 'cmp -s "$F" "$T/$BACKEND/orig.json"'
run "$F" uninstall.sh
check "second uninstall is a no-op" 'cmp -s "$F" "$T/$BACKEND/orig.json" && grep -q "nothing to remove" "$T/out"'

echo "our command already inside someone else's group"
F="$T/$BACKEND/shared.json"
jq --arg p "$P" '{hooks:{UserPromptSubmit:[{hooks:[{type:"command",command:"echo a"},{type:"command",command:$p}]}]}}' -n > "$F"
cp "$F" "$T/$BACKEND/shared-orig.json"
run "$F" install.sh
check "no duplicate prompt hook" '[[ $(count "$F" "$P") == 1 && $(count "$F" "$S") == 1 ]]'
run "$F" uninstall.sh
check "uninstall removes only ours, keeps their group" '[[ $(count "$F" "$P") == 0 && $(count "$F" "echo a") == 1 && $(jq ".hooks.UserPromptSubmit|length" "$F") == 1 ]]'

echo "invalid JSON"
F="$T/$BACKEND/bad.json"; echo '{ nope' > "$F"
run "$F" install.sh; rc=$?
check "refuses, nonzero exit, file untouched" '[[ $rc != 0 && $(cat "$F") == "{ nope" && $(nbak "$F") == 0 ]]'

echo "symlinked settings.json"
mkdir -p "$T/$BACKEND/link"; echo '{"model":"opus"}' | jq . > "$T/$BACKEND/link/real.json"; ln -s "$T/$BACKEND/link/real.json" "$T/$BACKEND/link/settings.json"
run "$T/$BACKEND/link/settings.json" install.sh
check "still a symlink, target updated" '[[ -L "$T/$BACKEND/link/settings.json" && $(count "$T/$BACKEND/link/real.json" "$P") == 1 ]]'

if [[ $BACKEND == jq ]]; then
echo "declining the prompt"
F="$T/$BACKEND/decline.json"; echo '{}' > "$F"
echo n | CLAUDE_SETTINGS="$F" SKIP_APP=1 ASSUME_YES=0 script -q /dev/null "$ROOT/scripts/install.sh" >"$T/out" 2>&1 </dev/null || true
check "file unchanged when not confirmed" '[[ $(cat "$F") == "{}" ]]'
fi

if [[ -n "$FIXTURE" ]]; then
echo "round trip on a copy of $FIXTURE"
F="$T/$BACKEND/real/settings.json"; mkdir -p "$T/$BACKEND/real"; cp "$FIXTURE" "$F"
run "$F" install.sh; run "$F" install.sh; run "$F" uninstall.sh
check "byte-identical after install x2 + uninstall" 'cmp -s "$F" "$FIXTURE"'
fi
}

suite jq

if [[ "${SKIP_SWIFT:-0}" != 1 ]]; then
  # A tiny CLI around the app's ClaudeHooks.swift: hooks add|remove <settings.json>
  cat > "$T/main.swift" <<'SWIFT'
import Foundation
let a = CommandLine.arguments, verb = a[1]
let hooks = ClaudeHooks(url: URL(fileURLWithPath: a[2]))
do {
  let plan = try hooks.plan(connect: verb == "add")
  if plan.changed { try hooks.apply(plan) } else { print("settings.json: nothing to \(verb).") }
} catch { print(error.localizedDescription); exit(1) }
SWIFT
  if swiftc -O -o "$T/hooks" "$ROOT/app/Sources/ClaudePosture/ClaudeHooks.swift" "$T/main.swift" 2>"$T/swiftc.log"; then
    suite swift

    echo "== swift output matches jq byte for byte"
    for fx in "$T"/jq/orig.json "$T"/jq/shared-orig.json ${FIXTURE:+"$FIXTURE"}; do
      for verb in add remove; do
        mkdir -p "$T/cmp"; cp "$fx" "$T/cmp/s.json"; cp "$fx" "$T/cmp/j.json"
        [[ $verb == remove ]] && { CLAUDE_SETTINGS="$T/cmp/j.json" SKIP_APP=1 "$ROOT/scripts/install.sh" -y >/dev/null 2>&1; cp "$T/cmp/j.json" "$T/cmp/s.json"; }
        CLAUDE_SETTINGS="$T/cmp/j.json" SKIP_APP=1 "$ROOT/scripts/$([[ $verb == add ]] && echo install || echo uninstall).sh" -y >/dev/null 2>&1
        "$T/hooks" "$verb" "$T/cmp/s.json" >/dev/null 2>&1
        check "$verb on $(basename "$fx")" 'cmp -s "$T/cmp/s.json" "$T/cmp/j.json"'
        rm -rf "$T/cmp"
      done
    done
  else
    bad "ClaudeHooks.swift compiles (see $T/swiftc.log)"
  fi
fi

echo "$pass passed, $fail failed  (temp files in $T)"
[[ $fail == 0 ]]
