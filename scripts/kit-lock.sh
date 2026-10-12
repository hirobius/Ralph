#!/usr/bin/env bash
# kit-lock.sh <ref> [kit-dir] (ralph#42) — print a consumer's
# ralph/kit.lock.json for the kit in <kit-dir> (default: this repo's kit/):
#   {"ref": "<ref>", "files": {"<name>": "<sha256>", ...}}
# The same shape the consumers' check-ralph-kit-drift.mjs reads (ops#492,
# ops#568). Files are exactly kit/MANIFEST.json's `kit` list, in its order,
# so the lock and the gate's drift guard can never list different files.
# Usage from a consumer: bash <ralph>/scripts/kit-lock.sh hirobius/ralph@v2 <ralph>/kit >ralph/kit.lock.json
set -uo pipefail

ref=${1:?usage: kit-lock.sh <ref> [kit-dir]}
dir=${2:-"$(cd "$(dirname "$0")/.." && pwd)/kit"}

files=$(jq -er '.kit[] | strings' "$dir/MANIFEST.json" 2>/dev/null) || {
  echo "kit-lock: no readable $dir/MANIFEST.json" >&2
  exit 1
}

sha256() { # GNU coreutils, else macOS shasum
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

pairs=""
while IFS= read -r f; do
  [ -f "$dir/$f" ] || {
    echo "kit-lock: $dir/$f is listed in the manifest but missing" >&2
    exit 1
  }
  pairs="$pairs$f"$'\t'"$(sha256 "$dir/$f")"$'\n'
done <<<"$files"

printf '%s' "$pairs" | jq -R -s --arg ref "$ref" '
  {ref: $ref, files: (split("\n") | map(select(length > 0) | split("\t") | {(.[0]): .[1]}) | add)}'
