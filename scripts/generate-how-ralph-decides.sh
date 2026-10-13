#!/usr/bin/env bash
# Generate docs/HOW-RALPH-DECIDES.md from kit/lib.sh decision tables.
#
# Usage:
#   bash scripts/generate-how-ralph-decides.sh            write docs/HOW-RALPH-DECIDES.md
#   bash scripts/generate-how-ralph-decides.sh --check    exit 1 when docs/HOW-RALPH-DECIDES.md is stale
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
      echo "usage: generate-how-ralph-decides.sh [--check] [--root <dir>]" >&2
      exit 2
      ;;
  esac
  shift
done

DOC_PATH=docs/HOW-RALPH-DECIDES.md
LIB_PATH=kit/lib.sh

[ -f "$ROOT/$LIB_PATH" ] || {
  echo "x $LIB_PATH is missing" >&2
  exit 1
}

build_doc() {
  cat <<'EOF'
<!-- ralph:how-decides:start — generated — do not hand-edit from kit/lib.sh by scripts/generate-how-ralph-decides.sh -->

# How Ralph Decides

How Ralph decides to approve, escalate or arm a pull request is determined by decision tables and priority logic in `kit/lib.sh`.

## Approver Decision Table

The `ralph_approver_decide` function evaluates PR facts against the rules below in row order (first match wins):

| Row | Condition | Decision | Code | Reason |
| --- | --- | --- | --- | --- |
EOF

  awk '
    /# First match wins:/ { inside = 1; next }
    inside && /^# *$/ { inside = 0 }
    inside {
      sub(/^# */, "")
      if (match($0, /^[0-9]+/)) {
        if (row != "") print row
        row = $0
      } else if (row != "") {
        row = row " " $0
      }
    }
    END { if (row != "") print row }
  ' "$ROOT/$LIB_PATH" | while IFS= read -r line; do
    num=$(echo "$line" | awk '{print $1}')
    rest=$(echo "$line" | sed 's/^[0-9]* //')
    cond=$(echo "$rest" | awk -F '→|->' '{print $1}' | sed 's/  */ /g; s/^ //; s/ $//')
    target=$(echo "$rest" | awk -F '→|->' '{print $2}' | sed 's/  */ /g; s/^ //; s/ $//')
    decision=$(echo "$target" | awk '{print $1}')
    code=$(echo "$target" | awk '{print $2}')
    reason=$(bash "$ROOT/$LIB_PATH" ralph_approver_reason "$code")
    cond_escaped=$(echo "$cond" | sed 's/|/\\|/g')
    printf '| %s | %s | %s | `%s` | %s |\n' "$num" "$cond_escaped" "$decision" "$code" "$reason"
  done

  cat <<'EOF'

## Auto-Merge Arming Priority Order

The `ralph_arm_reason` function determines whether auto-merge is armed and under which reason. Arming reasons are evaluated in the following priority order:

1. `ralph-approved` — PR carries the `ralph-approved` label.
2. `issue ralph-auto` — Linked issue carries the `ralph-auto` label.
3. `approver` — `RALPH_APPROVER=on` and `ralph_approver_decide` evaluated to `merge`.
4. `default posture` — `RALPH_DEFAULT_AUTO_MERGE` posture is enabled (`true`).

**Supervised Path Boundary:** A supervised-path diff blocks arming under every reason (including explicit `ralph-approved` and `issue ralph-auto` labels).
EOF
}

next_content="$(build_doc)"$'\n'

current_content=""
if [ -f "$ROOT/$DOC_PATH" ]; then
  read_file current_content "$ROOT/$DOC_PATH"
fi

if [ "$CHECK" -eq 1 ]; then
  if [ "$current_content" != "$next_content" ]; then
    echo "x $DOC_PATH is out of date. Run: bash scripts/generate-how-ralph-decides.sh" >&2
    exit 1
  fi
  echo "ok $DOC_PATH is up to date"
  exit 0
fi

mkdir -p "$ROOT/docs"
printf '%s' "$next_content" >"$ROOT/$DOC_PATH"
echo "ok wrote $DOC_PATH"
