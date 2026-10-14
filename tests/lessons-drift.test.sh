#!/usr/bin/env bash
# The vendored lessons copy in .claude/lessons matches its lock, and the recall hook is wired (ops#610).
#
# THE COPY. .claude/lessons/ is the fleet lessons ledger and the recall hook,
# vendored byte-identical from hirobius/ops (`pnpm lessons:vendor` there) with
# lessons.lock.json pinning the sha256 of each file. Ralph has no pre-commit
# hook and no package.json, so this suite is where an edited copy fails: run by
# `bash tests/run.sh`, which CI's "Kit decision-table tests" step runs.
#
# Each case builds a throwaway copy, so nothing here edits the real files.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

LESSONS="$REPO_DIR/.claude/lessons"
SETTINGS="$REPO_DIR/.claude/settings.json"

CASE_NAME=real-repo
out=$(node "$LESSONS/check-drift.mjs" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "the vendored lessons match their lock ($out)"

new_copy() { # <name> — a throwaway copy of .claude/lessons in $COPY
  CASE_NAME=$1
  COPY=$(mktemp -d "${TMPDIR:-/tmp}/ralph-lessons-XXXXXX")
  cp -R "$LESSONS" "$COPY/lessons"
}

new_copy edited-file
printf '\n// local edit\n' >>"$COPY/lessons/lib/lessons-recall.mjs"
out=$(node "$COPY/lessons/check-drift.mjs" 2>&1) && rc=0 || rc=$?
assert_eq 1 "$rc" "an edited vendored file fails the check"
assert_contains "$out" "lib/lessons-recall.mjs" "the failure names the edited file"
assert_contains "$out" "pnpm lessons:vendor" "the failure names the fix (re-run lessons:vendor from ops)"
rm -rf "$COPY"

new_copy edited-ledger
printf '{"id":"L-9999"}\n' >>"$COPY/lessons/learned-rules.jsonl"
out=$(node "$COPY/lessons/check-drift.mjs" 2>&1) && rc=0 || rc=$?
assert_eq 1 "$rc" "an edited ledger copy fails the check"
assert_contains "$out" "learned-rules.jsonl" "the failure names the ledger"
rm -rf "$COPY"

new_copy deleted-file
rm "$COPY/lessons/lessons-recall.mjs"
out=$(node "$COPY/lessons/check-drift.mjs" 2>&1) && rc=0 || rc=$?
assert_eq 1 "$rc" "a deleted vendored file fails the check"
assert_contains "$out" "[missing]" "the failure says the file is missing"
rm -rf "$COPY"

CASE_NAME=hooks-wired
hook_count() { # <jq selector for hook entries> — entries running the recall hook
  jq -r "[$1 | .hooks[].command | select(contains(\".claude/lessons/lessons-recall.mjs\"))] | length" "$SETTINGS"
}
assert_eq 1 "$(hook_count '.hooks.UserPromptSubmit[]')" "the recall hook runs on UserPromptSubmit"
assert_eq 1 "$(hook_count '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit")')" "the recall hook runs before Edit, Write and MultiEdit"
assert_eq 1 "$(hook_count '.hooks.PreToolUse[] | select(.matcher == "Bash")')" "the recall hook runs before Bash"

CASE_NAME=hook-runs
STATE=$(mktemp -d "${TMPDIR:-/tmp}/ralph-lessons-XXXXXX")
out=$(printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"ralph-lessons-test","prompt":"hello"}' |
  CLAUDE_PROJECT_DIR="$REPO_DIR" LESSONS_STATE_DIR="$STATE" node "$LESSONS/lessons-recall.mjs" 2>/dev/null) && rc=0 || rc=$?
assert_eq 0 "$rc" "the vendored recall hook exits 0"
if [ -z "$out" ] || printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null 2>&1; then
  _ok "its output is empty or hook JSON"
else
  _fail "its output is empty or hook JSON" "got: $out"
fi
rm -rf "$STATE"

report
