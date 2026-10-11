#!/usr/bin/env bash
# Gate arming wiring (ralph#25 / ralph#26).
#
# kit/lib.sh owns the decision (ralph_arm_reason, ralph_diff_is_supervised,
# both unit-tested in arm-reason.test.sh / supervised-paths.test.sh). This
# suite pins that the reusable gate actually CALLS it: the post-gate merge
# policy must reach `gh pr merge` only through ralph_arm_reason, fail closed
# when the kit or the diff can't be read, and name the supervised files when
# it holds a PR back. The workflow has no other test harness, so these are
# static reads of the step's script, as ralph#25's DoD asks ("assert by
# reading the if guard around the gh pr merge line").
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

WF="$REPO_DIR/.github/workflows/ralph-gate-reusable.yml"
# The merge-policy step: from its name to the end of the file (it is the
# last step of the job).
POLICY=$(awk '/- name: Post ralph-gate status \+ human-approved merge policy/{on=1} on' "$WF")

new_case policy_step_found
assert_eq 1 "$([ -n "$POLICY" ] && echo 1 || echo 0)" "the merge-policy step exists"

new_case policy_calls_arm_reason
assert_eq 1 "$(grep -c 'ralph_arm_reason "\$pr_ok" "\$issue_ok"' <<<"$POLICY")" \
  "the policy step decides through ralph_arm_reason with both label checks"

new_case diff_from_merge_base
assert_eq 1 "$(grep -c 'git diff --name-only "origin/\$base...HEAD"' <<<"$POLICY")" \
  "changed paths come from the merge base, so a late ralph-auto can't skip the check"

new_case every_merge_is_guarded
# Every `gh pr merge` in the policy step sits inside the `[ -n "$reason" ]`
# branch: walk the step, track that branch's if/fi depth, flag any merge
# outside it.
unguarded=$(awk '
  /if \[ -n "\$reason" \]; then/ { inside=1; depth=0; next }
  inside && /^[[:space:]]*if / { depth++ }
  inside && /^[[:space:]]*(elif|else)/ && depth==0 { inside=0 }
  inside && /^[[:space:]]*fi([[:space:]]|$)/ { if (depth==0) inside=0; else depth-- }
  /gh pr merge/ && !inside { print NR": "$0 }
' <<<"$POLICY")
assert_eq "" "$unguarded" "no gh pr merge outside the ralph_arm_reason branch"

new_case fails_closed
assert_eq 1 "$(grep -c 'type ralph_arm_reason' <<<"$POLICY")" \
  "a kit that did not load is checked for, not assumed"
assert_eq 1 "$(grep -c 'not arming (fail closed)' <<<"$POLICY" | awk '{print ($1>=1)}')" \
  "an unreadable kit or diff does not arm"

new_case names_supervised_files
assert_eq 1 "$(grep -c 'ralph_diff_is_supervised' <<<"$POLICY" | awk '{print ($1>=1)}')" \
  "a held-back PR is checked against the boundary"
assert_eq 1 "$(grep -c 'supervised path' <<<"$POLICY" | awk '{print ($1>=1)}')" \
  "the awaiting-approval comment names the supervised files"

new_case header_current
assert_eq 0 "$(grep -c 'Everything else waits' "$WF")" \
  "the header describes the boundary, not the pre-#238 posture"

report
