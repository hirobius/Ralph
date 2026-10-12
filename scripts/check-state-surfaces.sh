#!/usr/bin/env bash
# Gate for the state-surface registry (hirobius/ralph#37, spec hirobius/ops#576;
# a bash port of hds scripts/check-state-surfaces.mjs, minus its derived-fact
# scan). docs/state-surfaces.json lists every file or section that describes
# project state, and what keeps it true:
#
#   generated  built by a generator (`by`); `check` is the command that proves it fresh
#   checked    prose or data a named gate (`by`) compares to the code
#   editorial  hand-written; carries `owner`, `reviewedAt` (YYYY-MM-DD) and
#              `maxAgeDays`, and goes "review due" when it ages out
#
# Rules (the word after file:line in each report):
#   REGISTRY_MISSING / REGISTRY_INVALID  the registry is absent or malformed
#   SURFACE_MISSING    a registered path does not exist
#   BY_MISSING         `by` looks like a repo path and does not exist
#   GENERATED_STALE    --run-checks only: a declared `check` command failed
#   REVIEW_DUE         an editorial surface is older than its maxAgeDays. A
#                      warning (exit stays 0) unless --strict-review: a review
#                      date passing must not turn every unrelated kit PR red.
#   DEAD_REFERENCE     markdown that is not generated (README, CLAUDE, CONTRIBUTING,
#                      AGENTS, and registered editorial/checked files or the
#                      markdown inside registered directories) names a repo path
#                      (backticked, or a link target) that does not exist.
#                      Fenced code blocks are skipped.
#
# Optional registry keys: `ignoreReferences` (path prefixes docs name but this
# repo lacks, such as the per-repo files a consumer authors) and `alsoScan`
# (markdown files scanned even when unregistered).
#
# Usage:
#   bash scripts/check-state-surfaces.sh [--root <dir>] [--registry <path>]
#        [--today YYYY-MM-DD] [--run-checks] [--strict-review]
# Exit: 0 clean (warnings allowed), 1 violations.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$HERE/lib.sh"

ROOT=$(dirname "$HERE")
REGISTRY=docs/state-surfaces.json
TODAY=${STATE_SURFACES_TODAY:-$(today_utc)}
RUN_CHECKS=0
STRICT_REVIEW=0
while [ $# -gt 0 ]; do
  case $1 in
    --root)
      ROOT=$(cd "${2:?--root needs a directory}" && pwd)
      shift
      ;;
    --registry)
      REGISTRY=${2:?--registry needs a path}
      shift
      ;;
    --today)
      TODAY=${2:?--today needs YYYY-MM-DD}
      shift
      ;;
    --run-checks) RUN_CHECKS=1 ;;
    --strict-review) STRICT_REVIEW=1 ;;
    *)
      echo "usage: check-state-surfaces.sh [--root <dir>] [--registry <path>] [--today YYYY-MM-DD] [--run-checks] [--strict-review]" >&2
      exit 2
      ;;
  esac
  shift
done

VIOLATIONS=0
WARNINGS=0
SCANNED=0

violation() { # <file> <rule> <message> [line]
  VIOLATIONS=$((VIOLATIONS + 1))
  echo "$1:${4:--} $2 $3" >&2
}
warning() { # <file> <rule> <message>
  WARNINGS=$((WARNINGS + 1))
  echo "$1:- $2 (warning) $3" >&2
}
finish() {
  if [ "$VIOLATIONS" -eq 0 ]; then
    echo "ok check-state-surfaces ($1; $SCANNED markdown file(s) scanned; $WARNINGS warning(s))"
    exit 0
  fi
  echo "x check-state-surfaces: $VIOLATIONS violation(s)" >&2
  exit 1
}

reg="$ROOT/$REGISTRY"
if [ ! -f "$reg" ]; then
  violation "$REGISTRY" REGISTRY_MISSING "$REGISTRY does not exist; it lists every file that describes state."
  finish "no registry"
fi
if ! err=$(jq -e . "$reg" 2>&1 >/dev/null); then
  violation "$REGISTRY" REGISTRY_INVALID "$REGISTRY is not JSON (${err%%$'\n'*})."
  finish "no registry"
fi
if ! jq -e '(.surfaces | type) == "array"' "$reg" >/dev/null; then
  violation "$REGISTRY" REGISTRY_INVALID "$REGISTRY needs a \"surfaces\" array."
  finish "no registry"
fi

# path_of <kind: link|code> <raw> — the repo path a reference names (stdout), or
# return 1 when it is not a repo path (url, anchor, glob, placeholder, command).
path_of() {
  local kind=$1 p=$2
  p=${p#"${p%%[![:space:]]*}"}
  p=${p%"${p##*[![:space:]]}"}
  [ -n "$p" ] || return 1
  case $p in '#'* | /* | '~'* | @*) return 1 ;; esac
  [[ $p =~ ^[a-zA-Z][a-zA-Z0-9+.-]*: ]] && return 1
  [[ $p == *://* ]] && return 1
  p=${p%%[#?]*}
  if [[ $p =~ ^(.*):[0-9]+(-[0-9]+)?$ ]]; then p=${BASH_REMATCH[1]}; fi
  [ -n "$p" ] || return 1
  # shellcheck disable=SC1003
  [[ $p == *[\*\{\}\<\>\$\|\(\)\[\]=,\;\'\"\\\![:space:]]* ]] && return 1
  if [ "$kind" = code ]; then
    [[ $p == */* ]] || return 1
    if [[ $p == */ ]]; then
      local trimmed=${p%/}
      [[ $trimmed == */* ]] || return 1
    else
      shopt -s nocasematch
      [[ $p =~ \.(md|mdx|json|mjs|cjs|js|ts|tsx|jsx|css|ya?ml|txt|html|sh|svg)$ ]] || {
        shopt -u nocasematch
        return 1
      }
      shopt -u nocasematch
    fi
  fi
  printf '%s' "$p"
}

# references <file> — "line<TAB>kind<TAB>raw" for every backticked span and link
# target outside fenced code.
references() {
  awk '
    /^[ \t]*(```+|~~~+)/ {
      m = substr($0, match($0, /[`~]/), 1)
      if (fence == "") fence = m; else if (m == fence) fence = ""
      next
    }
    fence != "" { next }
    {
      s = $0
      while (match(s, /\]\([^) \t]+/)) {
        printf "%d\tlink\t%s\n", NR, substr(s, RSTART + 2, RLENGTH - 2)
        s = substr(s, RSTART + RLENGTH)
      }
      s = $0
      while (match(s, /`[^`]+`/)) {
        printf "%d\tcode\t%s\n", NR, substr(s, RSTART + 1, RLENGTH - 2)
        s = substr(s, RSTART + RLENGTH)
      }
    }' "$1"
}

resolves() { # <from-file> <path>
  local clean=${2%/}
  [ -e "$ROOT/$(dirname "$1")/$clean" ] || [ -e "$ROOT/$clean" ]
}

today_n=$(day_number "$TODAY") || {
  echo "x --today must be a calendar day (YYYY-MM-DD), not '$TODAY'" >&2
  exit 2
}

declare -A SEEN=()
declare -A KINDS=()
SCAN_LIST=()
US=$'\x1f'

while IFS= read -r row; do
  IFS=$US read -r path kind describes by owner reviewed maxage section check <<<"$row"
  label=${path:-"(no path)"}
  bad() { violation "$REGISTRY" REGISTRY_INVALID "$label: $1"; }
  if [ -z "$path" ]; then
    bad "every surface needs a path"
    continue
  fi
  [ -n "$describes" ] || bad 'needs "describes" (what state it holds)'
  case $kind in
    generated | checked | editorial) ;;
    *)
      bad "kind must be one of generated, checked, editorial, not \"$kind\""
      continue
      ;;
  esac
  key="$path#$section"
  if [ -n "${SEEN[$key]:-}" ]; then bad 'registered twice (give each section its own "section")'; fi
  SEEN[$key]=1
  KINDS[$kind]=$((${KINDS[$kind]:-0} + 1))

  if [ "$kind" != editorial ] && [ -z "$by" ]; then
    if [ "$kind" = generated ]; then bad 'a generated surface must name its generator in "by"'; else bad 'a checked surface must name its check in "by"'; fi
  fi
  review_n=''
  if [ "$kind" = editorial ]; then
    [ -n "$owner" ] || bad 'an editorial surface needs an "owner"'
    if review_n=$(day_number "$reviewed" 2>/dev/null); then :; else
      review_n=''
      bad "\"reviewedAt\" must be a calendar day (YYYY-MM-DD), not \"$reviewed\""
    fi
    if ! [[ $maxage =~ ^[0-9]+$ ]] || [ "$maxage" -lt 1 ]; then
      bad '"maxAgeDays" must be a positive integer'
      maxage=''
    fi
  fi

  if [ ! -e "$ROOT/$path" ]; then
    violation "$path" SURFACE_MISSING "$path is registered in $REGISTRY but does not exist; update or remove the entry."
    continue
  fi
  if [[ $by =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+\.[A-Za-z0-9_]+$ ]] && [ ! -e "$ROOT/$by" ]; then
    violation "$path" BY_MISSING "$path: \"by\" names $by, which does not exist."
  fi
  if [ -n "$review_n" ] && [ -n "$maxage" ]; then
    age=$((today_n - review_n))
    if [ "$age" -gt "$maxage" ]; then
      msg="$path review due: last reviewed $reviewed ($age days ago, max $maxage); ${owner:-its owner} re-reads it and bumps reviewedAt in $REGISTRY."
      if [ "$STRICT_REVIEW" -eq 1 ]; then violation "$path" REVIEW_DUE "$msg"; else warning "$path" REVIEW_DUE "$msg"; fi
    fi
  fi
  if [ "$RUN_CHECKS" -eq 1 ] && [ -n "$check" ]; then
    if ! (cd "$ROOT" && bash -c "$check" >/dev/null 2>&1); then
      violation "$path" GENERATED_STALE "$path: \`$check\` failed; regenerate it with ${by:-its generator}."
    fi
  fi
  # Markdown a person writes or a gate checks (generated text belongs to its generator).
  if [ "$kind" != generated ]; then
    if [ -d "$ROOT/$path" ]; then
      while IFS= read -r f; do SCAN_LIST+=("${f#"$ROOT"/}"); done < <(
        find "$ROOT/$path" -mindepth 1 \( -name node_modules -o -name '.*' \) -prune -o \
          -type f \( -name '*.md' -o -name '*.mdx' \) -print
      )
    elif [[ $path == *.md || $path == *.mdx ]]; then
      SCAN_LIST+=("$path")
    fi
  fi
done < <(jq -r '.surfaces[] | [
    (.path // ""), (.kind // ""), (.describes // ""), (.by // ""), (.owner // ""),
    (.reviewedAt // ""),
    (if .maxAgeDays == null then "" elif (.maxAgeDays | type) == "number" then (.maxAgeDays | tostring) else "!" end),
    (.section // ""), (.check // "")
  ] | join("\u001f")' "$reg")

# Front-door files are scanned even when unregistered.
while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$ROOT/$f" ] && SCAN_LIST+=("$f")
done < <(jq -r '(.alsoScan // ["README.md", "CLAUDE.md", "CONTRIBUTING.md", "AGENTS.md"])[]' "$reg")

IGNORE=()
while IFS= read -r p; do IGNORE+=("$p"); done < <(jq -r '(.ignoreReferences // [])[]' "$reg")

while IFS= read -r file; do
  [ -n "$file" ] || continue
  SCANNED=$((SCANNED + 1))
  while IFS=$'\t' read -r line kind raw; do
    p=$(path_of "$kind" "$raw") || continue
    skip=0
    for prefix in "${IGNORE[@]+"${IGNORE[@]}"}"; do
      case $p in "$prefix"*) skip=1 ;; esac
    done
    [ "$skip" -eq 1 ] && continue
    resolves "$file" "$p" || violation "$file" DEAD_REFERENCE "$file references $p, which does not exist; fix or remove the reference." "$line"
  done < <(references "$ROOT/$file")
done < <(printf '%s\n' "${SCAN_LIST[@]+"${SCAN_LIST[@]}"}" | LC_ALL=C sort -u)

summary=''
for k in generated checked editorial; do
  [ -n "${KINDS[$k]:-}" ] && summary="${summary:+$summary, }${KINDS[$k]} $k"
done
finish "${summary:-no surfaces}"
