#!/usr/bin/env bash
# shellcheck disable=SC2016 # grep patterns below are literal workflow text
# ralph#46 (workflow half of ralph#10): the run reusable turns
# claude-code-action's execution_file into RALPH_RESULT_FILE, so a silent
# failed attempt carries the agent's own final words (reconcile appends the
# tail; see reconcile.test.sh 10b).
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

new_case setup
# shellcheck source=kit/lib.sh
. "$CASE/ralph/lib.sh"

new_case result_message
cat >"$CASE/exec.json" <<'JSON'
[{"type":"system","subtype":"init"},
 {"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}},
 {"type":"result","subtype":"success","result":"Stopped: the issue needs a schema decision."}]
JSON
ralph_extract_result "$CASE/exec.json" "$CASE/out.txt"
assert_eq "Stopped: the issue needs a schema decision." "$(cat "$CASE/out.txt")" "the result message's text is extracted"

new_case assistant_fallback
cat >"$CASE/exec.json" <<'JSON'
[{"type":"assistant","message":{"content":[{"type":"text","text":"first"}]}},
 {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"},{"type":"text","text":"last words"}]}}]
JSON
ralph_extract_result "$CASE/exec.json" "$CASE/out.txt"
assert_eq "last words" "$(cat "$CASE/out.txt")" "no result message: the last assistant text"

new_case missing_file
ralph_extract_result "$CASE/nope.json" "$CASE/out.txt"
assert_eq 0 "$?" "a missing execution file is not an error"
assert_eq 0 "$([ -s "$CASE/out.txt" ] && echo 1 || echo 0)" "and writes nothing"

new_case malformed_json
echo "{not json" >"$CASE/exec.json"
ralph_extract_result "$CASE/exec.json" "$CASE/out.txt"
assert_eq 0 "$?" "malformed JSON is not an error"
assert_eq 0 "$([ -s "$CASE/out.txt" ] && echo 1 || echo 0)" "and writes nothing"

new_case workflow_wiring
WF="$REPO_DIR/.github/workflows/ralph-run-reusable.yml"
STEP=$(awk '/- name: Reconcile — state decides what actually happened/{on=1;next} on && /- name: /{exit} on' "$WF")
assert_eq 1 "$(grep -c 'EXECUTION_FILE: \${{ steps.work.outputs.execution_file }}' <<<"$STEP")" "reconcile gets the action's execution_file"
assert_eq 1 "$(grep -c 'ralph_extract_result "\$EXECUTION_FILE"' <<<"$STEP")" "and extracts the agent's final text from it"
assert_eq 1 "$(grep -c 'export RALPH_RESULT_FILE' <<<"$STEP")" "and passes it to reconcile as RALPH_RESULT_FILE"

report
