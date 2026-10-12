#!/usr/bin/env bash
# Generate AGENTS.md, Ralph's agent front door (hirobius/ralph#37, spec
# hirobius/ops#576): what Ralph is, the read order for an agent working on the
# kit, where live state is, and an index of every document in
# docs/state-surfaces.json grouped by kind.
#
# The intro (title, read order, working rules, where live state is) is
# editorial: docs/agents-intro.md, registered in the registry and included
# verbatim. The whole file up to the front-door end marker is generated;
# hand-written notes may follow the end marker, and the generator keeps them
# byte for byte.
# Nothing here records a version, a count or open work: those are derived, and
# ops states them live. Deterministic (no run dates), so --check compares
# exact bytes.
#
# Usage:
#   bash scripts/generate-agents-md.sh            write AGENTS.md
#   bash scripts/generate-agents-md.sh --check    exit 1 when AGENTS.md is stale
#   --root <dir>   read and write under <dir> instead of the repo (tests)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$HERE/lib.sh"

ROOT=$(dirname "$HERE")
CHECK=0
while [ $# -gt 0 ]; do
  case $1 in
    --check) CHECK=1 ;;
    --root)
      ROOT=$(cd "${2:?--root needs a directory}" && pwd)
      shift
      ;;
    *)
      echo "usage: generate-agents-md.sh [--check] [--root <dir>]" >&2
      exit 2
      ;;
  esac
  shift
done

AGENTS_PATH=AGENTS.md
REGISTRY_PATH=docs/state-surfaces.json
INTRO_PATH=docs/agents-intro.md
FRONT_DOOR_START='<!-- ralph:front-door:start — generated from docs/state-surfaces.json by scripts/generate-agents-md.sh; do not hand-edit until the end marker. -->'
FRONT_DOOR_END='<!-- ralph:front-door:end -->'

[ -f "$ROOT/$REGISTRY_PATH" ] || {
  echo "x $REGISTRY_PATH is missing; it lists every file that describes state." >&2
  exit 1
}
jq -e '.surfaces | type == "array"' "$ROOT/$REGISTRY_PATH" >/dev/null 2>&1 || {
  echo "x $REGISTRY_PATH is not JSON with a \"surfaces\" array." >&2
  exit 1
}

[ -f "$ROOT/$INTRO_PATH" ] || {
  echo "x $INTRO_PATH is missing; it is the hand-written intro this generator includes (title, read order, where live state is)." >&2
  exit 1
}
INTRO=$(cat "$ROOT/$INTRO_PATH")

# index_section <kind> <title> <gloss> — one "### Title" list, or nothing when
# the registry has no surface of that kind.
index_section() {
  local rows
  rows=$(jq -r --arg kind "$1" '
    def code: "`" + . + "`";
    def upkeep:
      if .kind == "editorial" then "\(.owner), reviewed \(.reviewedAt), re-read within \(.maxAgeDays) days."
      else (if .kind == "generated" then "Built" else "Checked" end) + " by \(.by | code)."
      end;
    def flat: tostring | gsub("[\r\n]+"; " ");
    .surfaces[] | select(.kind == $kind)
    | "- \(.path | code)\(if .section then " (\(.section))" else "" end): \(.describes | flat). \(upkeep | flat)"
  ' "$ROOT/$REGISTRY_PATH")
  [ -n "$rows" ] || return 0
  printf '### %s\n\n%s\n\n%s\n\n' "$2" "$3" "$rows"
}

build_block() {
  printf '%s\n\n' "$FRONT_DOOR_START"
  printf '%s\n\n' "$INTRO"
  cat <<'EOF2'
## Documents and what keeps them true

Built from `docs/state-surfaces.json`, which `scripts/check-state-surfaces.sh` gates. Re-read an editorial document, bump its `reviewedAt` there, then run `bash scripts/generate-agents-md.sh`.

EOF2
  index_section generated Generated 'A script builds it; its `--check` fails when it is stale. Do not hand-edit.'
  index_section checked Checked 'Kept true by a named test or gate that exercises it or compares it with the code.'
  index_section editorial Editorial 'Written by a person; the registry carries who, and when it was last re-read.'
  printf '%s' "$FRONT_DOOR_END"
}

current=''
tail=$'\n'
if [ -f "$ROOT/$AGENTS_PATH" ]; then
  read_file current "$ROOT/$AGENTS_PATH"
  case $current in
    *"$FRONT_DOOR_END"*) tail=${current#*"$FRONT_DOOR_END"} ;;
  esac
fi
next="$(build_block)$tail"

if [ "$CHECK" -eq 1 ]; then
  if [ "$current" != "$next" ]; then
    echo "x $AGENTS_PATH is out of date with $REGISTRY_PATH. Run: bash scripts/generate-agents-md.sh (hand-edit only below the front-door end marker)." >&2
    exit 1
  fi
  echo "ok $AGENTS_PATH is up to date"
  exit 0
fi
printf '%s' "$next" >"$ROOT/$AGENTS_PATH"
echo "ok wrote $AGENTS_PATH"
