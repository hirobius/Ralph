#!/usr/bin/env bash
# Consumer pin audit tests (ralph#45, spec #40): scripts/audit-consumer-pins.sh
# reads each repo's caller workflows through `gh api` and prints one line per
# hirobius/ralph use: `repo workflow ref behind`. A repo it cannot read prints
# `repo - unknown -` and the run exits 2. Read-only.
#
# Uses a dedicated gh stub (tests/stubs-pins/gh) because the audit needs
# different fixtures (a whole repo tree and compare results) than the kit's stub.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

AUDIT="$REPO_DIR/scripts/audit-consumer-pins.sh"
SHA=0123456789abcdef0123456789abcdef01234567

new_fix() { # <name>
  CASE_NAME=$1
  PINS_FIX=$(mktemp -d "${TMPDIR:-/tmp}/ralph-pins-XXXXXX")
  export PINS_FIX
  export PATH="$TESTS_DIR/stubs-pins:$ORIG_PATH"
}

repo_file() { # <owner/repo> <file>  (yml on stdin)
  local d="$PINS_FIX/${1/\//__}"
  mkdir -p "$d"
  cat >"$d/$2"
  echo "$2" >>"$d/workflows.txt"
}

run() { # <args...>
  RUN_CODE=0
  RUN_OUT=$(bash "$AUDIT" "$@" 2>&1) || RUN_CODE=$?
}

new_fix mixed-pins
repo_file hirobius/ops ralph-run.yml <<EOF2
jobs:
  run:
    uses: hirobius/ralph/.github/workflows/ralph-run-reusable.yml@v2
EOF2
repo_file hirobius/ops ralph-gate.yml <<EOF2
jobs:
  gate:
    uses: Hirobius/Ralph/.github/workflows/ralph-gate-reusable.yml@$SHA
    # uses: hirobius/ralph/.github/workflows/ralph-gate-reusable.yml@v0
EOF2
repo_file hirobius/ops ci.yml <<EOF2
jobs:
  build:
    runs-on: ubuntu-latest
EOF2
repo_file hirobius/hds ralph-triage.yml <<EOF2
jobs:
  triage:
    uses: hirobius/ralph/.github/workflows/ralph-triage-reusable.yml@v1
EOF2
echo 0 >"$PINS_FIX/compare_v1.txt"
echo 3 >"$PINS_FIX/compare_v2.txt"
echo 17 >"$PINS_FIX/compare_$SHA.txt"
run hirobius/ops hirobius/hds
assert_eq 0 "$RUN_CODE" "readable repos exit 0"
assert_contains "$RUN_OUT" "hirobius/ops ralph-run.yml v2 3" "@v2 parsed with its distance behind main"
assert_contains "$RUN_OUT" "hirobius/ops ralph-gate.yml $SHA 17" "@<sha> parsed (owner/repo matched case-insensitively)"
assert_contains "$RUN_OUT" "hirobius/hds ralph-triage.yml v1 0" "@v1 parsed"
case $RUN_OUT in *'v0'*) _fail "a commented-out use is ignored" ;; *) _ok "a commented-out use is ignored" ;; esac
case $RUN_OUT in *'ci.yml'*) _fail "a workflow with no ralph use prints nothing" ;; *) _ok "a workflow with no ralph use prints nothing" ;; esac
assert_eq 3 "$(printf '%s\n' "$RUN_OUT" | wc -l | tr -d ' ')" "one line per use"

new_fix unreadable
repo_file hirobius/hds ralph-run.yml <<EOF2
    uses: hirobius/ralph/.github/workflows/ralph-run-reusable.yml@v1
EOF2
echo 0 >"$PINS_FIX/compare_v1.txt"
run hirobius/gone hirobius/hds
assert_eq 2 "$RUN_CODE" "an unreadable repo exits 2"
assert_contains "$RUN_OUT" "hirobius/gone - unknown -" "the unreadable repo prints unknown"
assert_contains "$RUN_OUT" "hirobius/hds ralph-run.yml v1 0" "the other repo is still audited"

new_fix compare-fails
repo_file hirobius/ops ralph-run.yml <<EOF2
    uses: hirobius/ralph/.github/workflows/ralph-run-reusable.yml@v9
EOF2
run hirobius/ops
assert_eq 0 "$RUN_CODE" "a failed compare is not fatal"
assert_contains "$RUN_OUT" "hirobius/ops ralph-run.yml v9 ?" "behind is ? when compare fails"

new_fix defaults
run
assert_eq 2 "$RUN_CODE" "defaults to the three consumer repos (all unreadable here)"
assert_contains "$RUN_OUT" "hirobius/ops - unknown -" "default repo ops"
assert_contains "$RUN_OUT" "hirobius/hds - unknown -" "default repo hds"
assert_contains "$RUN_OUT" "hirobius/site-engine - unknown -" "default repo site-engine"

report
