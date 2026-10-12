#!/usr/bin/env bash
# Consumer pin audit (ralph#45, ADR-009 section 2): which ref of the Ralph
# reusable workflows does each consumer run, and how far behind main is it?
# Read-only: only `gh api` GETs.
#
# Usage: scripts/audit-consumer-pins.sh [owner/repo ...]
#   default repos: hirobius/ops hirobius/hds hirobius/site-engine
# Output, one line per use: `repo workflow ref behind`; behind is the commits
# main is ahead of the ref, or ? when it cannot be told. A repo that cannot be
# read prints `repo - unknown -`, and the run exits 2.
set -uo pipefail

repos=("$@")
[ "${#repos[@]}" -gt 0 ] || repos=(hirobius/ops hirobius/hds hirobius/site-engine)

declare -A behind_cache
behind() { # <ref>
  local ref=$1 n
  if [ -z "${behind_cache[$ref]+x}" ]; then
    n=$(gh api "repos/hirobius/ralph/compare/$ref...main" --jq .ahead_by 2>/dev/null) || n="?"
    [ -n "$n" ] || n="?"
    behind_cache[$ref]=$n
  fi
  printf '%s' "${behind_cache[$ref]}"
}

rc=0
for r in "${repos[@]}"; do
  if ! files=$(gh api "repos/$r/contents/.github/workflows" --jq '.[].name' 2>/dev/null); then
    echo "$r - unknown -"
    rc=2
    continue
  fi
  while IFS= read -r f; do
    case $f in *.yml | *.yaml) ;; *) continue ;; esac
    if ! content=$(gh api "repos/$r/contents/.github/workflows/$f" --jq .content 2>/dev/null | base64 -d 2>/dev/null); then
      echo "$r $f unknown -"
      rc=2
      continue
    fi
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      echo "$r $f $ref $(behind "$ref")"
    done < <(
      grep -v '^[[:space:]]*#' <<<"$content" |
        grep -ioE 'hirobius/ralph/\.github/workflows/[^@[:space:]]+@[A-Za-z0-9._/-]+' |
        sed 's/^[^@]*@//'
    )
  done <<<"$files"
done
exit "$rc"
