#!/usr/bin/env bash
# kit-drift.sh <vendored-dir> <engine-kit-dir> (ralph#42) — print each kit
# file whose vendored copy differs from the engine's, one per line.
#
# The file list comes from <engine-kit-dir>/MANIFEST.json (`kit` entries
# only; `perRepo` files are never compared). A manifest file missing from the
# vendored dir is drift: that is how a new kit file gets noticed.
#
# An engine revision without a readable manifest (anything before ralph#42)
# falls back to the legacy list, with the legacy rule: a file the consumer
# never vendored is not drift. The gate calls this script from the same
# engine checkout as the manifest, so the two always match.
set -uo pipefail

vendored=${1:?usage: kit-drift.sh <vendored-dir> <engine-kit-dir>}
engine=${2:?usage: kit-drift.sh <vendored-dir> <engine-kit-dir>}

if files=$(jq -er '.kit | map(select(type == "string")) | .[]' "$engine/MANIFEST.json" 2>/dev/null) && [ -n "$files" ]; then
  while IFS= read -r f; do
    cmp -s "$vendored/$f" "$engine/$f" || echo "$f"
  done <<<"$files"
else
  echo "kit-drift: no readable $engine/MANIFEST.json — using the legacy list" >&2
  for f in lib.sh next.sh run.sh loop.sh status.sh prompt.md; do
    if [ -f "$vendored/$f" ] && ! cmp -s "$vendored/$f" "$engine/$f"; then
      echo "$f"
    fi
  done
fi
