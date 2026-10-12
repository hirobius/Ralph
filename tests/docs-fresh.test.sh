#!/usr/bin/env bash
# The real repo's docs are fresh (ralph#37, spec ops#576). This is the wiring
# that puts the generated-docs and state-surface gates into `bash tests/run.sh`
# (so CI's "Kit decision-table tests" step runs them): AGENTS.md and README's
# test list match their generators, and docs/state-surfaces.json holds (paths
# exist, no dead references in markdown, every `check` command passes).
#
# A "review due" date is a warning here, never a failure: a date passing must
# not redden unrelated kit PRs. Run scripts/check-state-surfaces.sh
# --strict-review for the periodic sweep.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

CASE_NAME=real-repo
out=$(bash "$REPO_DIR/scripts/generate-agents-md.sh" --check 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "AGENTS.md matches docs/state-surfaces.json ($out)"

out=$(bash "$REPO_DIR/scripts/generate-readme-tests.sh" --check 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "README's test list matches tests/*.test.sh ($out)"

out=$(bash "$REPO_DIR/scripts/check-state-surfaces.sh" --run-checks 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "the state-surface registry holds ($out)"

report
