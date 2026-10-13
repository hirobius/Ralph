#!/usr/bin/env bash
# The vendored skills tooling and guardrail-drift gate fire on drift (fleet drift sweep, ops#552).
#
# THE COPIES. skills-lock.json pins every skill under .claude/skills/ and
# docs/guardrails/shared-manifest.json pins the scripts below to hirobius/ops, the
# canonical source. Ralph has no pre-commit hook and no package.json, so this suite
# is where an edited skill or script fails: run by `bash tests/run.sh`, which CI's
# "Kit decision-table tests" step runs.
#
# Each case builds a throwaway copy, so nothing here edits the real files.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

new_copy() { # <name> — a throwaway repo root in $COPY holding the gates' inputs
  CASE_NAME=$1
  COPY=$(mktemp -d "${TMPDIR:-/tmp}/ralph-drift-XXXXXX")
  mkdir -p "$COPY/.claude" "$COPY/docs"
  cp -R "$REPO_DIR/scripts" "$COPY/scripts"
  cp -R "$REPO_DIR/docs/guardrails" "$COPY/docs/guardrails"
  cp -R "$REPO_DIR/.claude/skills" "$COPY/.claude/skills"
  cp "$REPO_DIR/skills-lock.json" "$COPY/"
}

CASE_NAME=real-repo
out=$(node "$REPO_DIR/scripts/check-skills-lock.mjs" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "every pinned skill matches the lock ($out)"
out=$(node "$REPO_DIR/scripts/check-guardrail-drift.mjs" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "every shared script matches the manifest ($out)"

new_copy edited-skill
printf '\nlocal edit\n' >>"$COPY/.claude/skills/tdd/SKILL.md"
out=$(node "$COPY/scripts/check-skills-lock.mjs" 2>&1) && rc=0 || rc=$?
assert_eq 1 "$rc" "an edited skill fails the lock check"
assert_contains "$out" "tdd" "the failure names the skill"
rm -rf "$COPY"

new_copy deleted-skill
rm -r "$COPY/.claude/skills/triage"
out=$(node "$COPY/scripts/check-skills-lock.mjs" 2>&1) && rc=0 || rc=$?
assert_eq 1 "$rc" "a deleted skill fails the lock check"
assert_contains "$out" "triage" "the failure names the skill"
rm -rf "$COPY"

new_copy edited-script
printf '\n// local edit\n' >>"$COPY/scripts/install-skills.mjs"
out=$(node "$COPY/scripts/check-guardrail-drift.mjs" 2>&1) && rc=0 || rc=$?
assert_eq 1 "$rc" "an edited shared script fails the drift check"
assert_contains "$out" "install-skills.mjs" "the failure names the script"
rm -rf "$COPY"

new_copy consumer-write-refused
out=$(node "$COPY/scripts/check-guardrail-drift.mjs" --write 2>&1) && rc=0 || rc=$?
assert_eq 2 "$rc" "a consumer cannot re-pin its own drift"
rm -rf "$COPY"

report
