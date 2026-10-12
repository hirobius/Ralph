#!/usr/bin/env bash
# Generate AGENTS.md, Ralph's agent front door (hirobius/ralph#37, spec
# hirobius/ops#576): what Ralph is, the read order for an agent working on the
# kit, where live state is, and an index of every document in
# docs/state-surfaces.json grouped by kind.
#
# The whole file up to the front-door end marker is generated. Hand-written
# notes may follow the end marker; the generator keeps them byte for byte.
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
OPS_STANDING_URL=https://hirobius-ops-adrian-6234s-projects.vercel.app/ops/standing
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

# index_section <kind> <title> <gloss> — one "### Title" list, or nothing when
# the registry has no surface of that kind.
index_section() {
  local rows
  rows=$(jq -r --arg kind "$1" '
    def code: "`" + . + "`";
    def upkeep:
      if .kind == "editorial" then "\(.owner), reviewed \(.reviewedAt), re-read within \(.maxAgeDays) days."
      elif .by == .path then "Generated at runtime."
      else (if .kind == "generated" then "Built" else "Checked" end) + " by \(.by | code)."
      end;
    .surfaces[] | select(.kind == $kind)
    | "- \(.path | code)\(if .section then " (\(.section))" else "" end): \(.describes). \(upkeep)"
  ' "$ROOT/$REGISTRY_PATH")
  [ -n "$rows" ] || return 0
  printf '### %s\n\n%s\n\n%s\n\n' "$2" "$3" "$rows"
}

build_block() {
  printf '%s\n\n' "$FRONT_DOOR_START"
  cat <<EOF2
# AGENTS.md: Ralph

Ralph is the org-level autonomous issue-to-PR loop engine: two reusable GitHub workflows plus a bash kit (\`kit/\`) that hirobius repos vendor.

## Read order

1. \`README.md\`: what the kit does, how a repo adopts it, and how \`v1\` is released.
2. \`kit/lib.sh\`: the decision functions (reconcile, arming, supervised paths); \`kit/next.sh\` (selection), \`kit/run.sh\` (one iteration), \`kit/loop.sh\`, \`kit/prompt.md\` (the iteration prompt).
3. \`.github/workflows/\`: the run, gate and triage reusables (each file's header comment is its contract).
4. \`tests/\`: decision-table tests with \`gh\` and \`git\` stubbed. Run all of them with \`bash tests/run.sh\`; extend them whenever reconcile or selection semantics change.

Rules for working here:

- \`kit/\` is vendored byte-identical by consumer repos. A kit change is a fleet change; the gate's drift guard tells each consumer to re-sync.
- Callers pin \`@v1\`, which is a branch, not a tag. Only backward-compatible changes move it.
- A change under \`.github/workflows/\` needs a human push: the bot token lacks the \`workflows\` scope.
- Generated sections (this file, the test list in \`README.md\`) are rebuilt by their generators, never hand-edited. After changing \`docs/state-surfaces.json\` or \`tests/\`, run \`bash scripts/generate-agents-md.sh\` and \`bash scripts/generate-readme-tests.sh\`.

## Where live state is

Nothing in the repo records the queue, the open work or what is blocked: ops derives them. Read ops \`/ops/standing\` (every verdict from live data): $OPS_STANDING_URL

For one loop's own health (queue order, in-flight PRs, claims, recent runs) run \`kit/status.sh\` (vendored as \`ralph/status.sh\` in a consumer repo). Open work for this repo is GitHub Issues here.

## Documents and what keeps them true

Built from \`docs/state-surfaces.json\`, which \`scripts/check-state-surfaces.sh\` gates. Re-read an editorial document, bump its \`reviewedAt\` there, then run \`bash scripts/generate-agents-md.sh\`.

EOF2
  index_section generated Generated 'A script builds it; its `--check` fails when it is stale. Do not hand-edit.'
  index_section checked Checked 'Hand-kept, but a gate compares it with the code.'
  index_section editorial Editorial 'Written by a person; the registry carries who, and when it was last re-read.'
  printf '%s' "$FRONT_DOOR_END"
}

current=''
tail=$'\n'
if [ -f "$ROOT/$AGENTS_PATH" ]; then
  current=$(read_file "$ROOT/$AGENTS_PATH")
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
