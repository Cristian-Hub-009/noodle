#!/bin/bash
# Assembles the website into build/site (site/ plus the app's figures). Prints the folder.
# Env: OUT=<dir> (default build/site)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/build/site}"

rm -rf "$OUT"
mkdir -p "$OUT"
rsync -a --exclude '.DS_Store' "$ROOT/site/" "$OUT/"
rsync -a --exclude '.DS_Store' "$ROOT/app/Resources/figures/" "$OUT/figures/"
echo "$OUT"
