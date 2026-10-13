#!/usr/bin/env bash
# shellcheck disable=SC2016 # grep patterns below are literal workflow text
# Approver gate wiring (ralph#44): RALPH_APPROVER=off|shadow|on. The kit owns
# the pieces (ralph_approver_mode, ralph_approver_facts, ralph_approver_act,
# ralph_arm_reason's approver arg), tested here with gh stubbed; the last
# cases pin that the reusable gate calls them, and that `off` (the default)
# changes nothing.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

load() { # fresh kit in this case's sandbox
  # shellcheck source=kit/lib.sh
  . "$CASE/ralph/lib.sh"
}

# ── mode ───────────────────────────────────────────────────────────────
new_case mode
load
assert_eq off "$(RALPH_APPROVER='' ralph_approver_mode)" "empty is off"
assert_eq off "$(unset RALPH_APPROVER; ralph_approver_mode)" "unset is off"
assert_eq shadow "$(RALPH_APPROVER=shadow ralph_approver_mode)" "shadow"
assert_eq on "$(RALPH_APPROVER=on ralph_approver_mode)" "on"
assert_eq off "$(RALPH_APPROVER=shdow ralph_approver_mode 2>/dev/null)" "a typo is off"
assert_contains "$(RALPH_APPROVER=shdow ralph_approver_mode 2>&1 >/dev/null)" "shdow" "and the typo is named on stderr"

# ── facts ──────────────────────────────────────────────────────────────
new_case facts_all_clear
load
echo '{"verdict":"approve","summary":"ok","security":"none"}' >"$CASE/v.json"
facts=$(printf 'src/a.ts\n' | ralph_approver_facts success "$CASE/v.json" true)
assert_eq "merge policy-clear" "$(ralph_approver_decide <<<"$facts")" "green + approve + clean diff → merge"
assert_contains "$facts" "approver=off" "Phase 1 reports the model approver as off"
assert_contains "$facts" "disagree=false" "Phase 1 has one reviewer, so no disagreement"

new_case facts_gate_red
load
facts=$(printf 'src/a.ts\n' | ralph_approver_facts failure "$CASE/none.json" true)
assert_contains "$facts" "gate=red" "a failed gate step is red"
assert_contains "$facts" "review=none" "no verdict.json is review=none"

new_case facts_request_changes
load
echo '{"verdict":"request_changes","security":"low"}' >"$CASE/v.json"
facts=$(printf 'a\n' | ralph_approver_facts success "$CASE/v.json" true)
assert_contains "$facts" "review=request_changes" "the verdict is read"
assert_contains "$facts" "security=low" "the severity is read"

new_case facts_missing_or_bad_security
load
echo '{"verdict":"approve"}' >"$CASE/v.json"
assert_contains "$(printf 'a\n' | ralph_approver_facts success "$CASE/v.json" true)" "security=unknown" "a missing severity is unknown"
echo '{"verdict":"approve","security":"scary"}' >"$CASE/v.json"
assert_contains "$(printf 'a\n' | ralph_approver_facts success "$CASE/v.json" true)" "security=unknown" "an unrecognised severity is unknown"
echo '{not json' >"$CASE/v.json"
facts=$(printf 'a\n' | ralph_approver_facts success "$CASE/v.json" true)
assert_contains "$facts" "review=none" "unparseable verdict.json is no review"

new_case facts_supervised
load
echo '{"verdict":"approve","security":"none"}' >"$CASE/v.json"
export RALPH_SUPERVISED_CMD="printf 'lib/billing/\n'"
assert_contains "$(printf 'lib/billing/x.ts\n' | ralph_approver_facts success "$CASE/v.json" true)" "supervised=true" "a supervised path"
assert_contains "$(printf 'docs/x.md\n' | ralph_approver_facts success "$CASE/v.json" true)" "supervised=false" "an unsupervised path"
assert_contains "$(printf 'docs/x.md\n' | ralph_approver_facts success "$CASE/v.json" false)" "supervised=unknown" "an unreadable diff"
export RALPH_SUPERVISED_CMD="false"
assert_contains "$(printf 'docs/x.md\n' | ralph_approver_facts success "$CASE/v.json" true 2>/dev/null)" "supervised=true" "a broken boundary command fails closed"
unset RALPH_SUPERVISED_CMD

# ── act ────────────────────────────────────────────────────────────────
new_case act_off_does_nothing
load
ralph_approver_act off 12 7 escalate supervised-path
assert_eq "" "$(cat "$GH_MUT_LOG")" "off: no comment, no label"

new_case act_shadow_comments_only
load
ralph_approver_act shadow 12 7 escalate supervised-path
assert_mutation "gh pr comment 12" "shadow posts the verdict on the PR"
assert_mutation "approver (shadow): escalate" "the comment names the decision"
assert_no_mutation "pr edit" "shadow never labels"
assert_no_mutation "issue comment" "shadow never comments on the issue"

new_case act_on_escalate
load
ralph_approver_act on 12 7 escalate security-finding
assert_mutation "gh pr edit 12 --add-label needs-adrian" "escalate labels the PR needs-adrian"
assert_mutation "gh issue comment 7" "the reason goes on the linked issue"
assert_mutation "> $(ralph_approver_reason security-finding)" "quoted verbatim"
assert_mutation "security-finding" "with its code"

new_case act_on_park_without_issue
load
ralph_approver_act on 12 "" park gate-red 2>/dev/null
assert_mutation "gh pr edit 12 --add-label needs-adrian" "park labels the PR (a parked PR frees single-flight, ops#476)"
assert_no_mutation "issue comment" "no linked issue, no issue comment"

new_case act_on_merge
load
ralph_approver_act on 12 7 merge policy-clear
assert_no_mutation "pr edit" "merge adds no label"
assert_mutation "gh pr comment 12" "merge posts the verdict"

new_case act_pages_on_unavailable
load
out=$(ralph_approver_act on 12 7 escalate approver-unavailable 2>&1)
assert_contains "$out" "not pinging" "an approver that can't run pages Discord (no webhook here: logged)"

# ── arm reason: approver is one more reason, behind the boundary ───────
new_case arm_reason_approver
load
assert_eq "approver" "$(printf 'docs/a.md\n' | ralph_arm_reason false false true)" "approver merge arms"
assert_eq "ralph-approved" "$(printf 'docs/a.md\n' | ralph_arm_reason true false true)" "a human label still wins the name"
export RALPH_SUPERVISED_CMD="printf 'docs/\n'"
assert_eq "" "$(printf 'docs/a.md\n' | ralph_arm_reason false false true)" "approver never arms a supervised diff"
unset RALPH_SUPERVISED_CMD
assert_eq "" "$(printf 'docs/a.md\n' | ralph_arm_reason false false)" "old 2-arg calls unchanged"

# ── the reusable gate calls it ─────────────────────────────────────────
new_case gate_wiring
WF="$REPO_DIR/.github/workflows/ralph-gate-reusable.yml"
STEP=$(awk '/- name: Approver verdict/{on=1;next} on && /- name: /{exit} on' "$WF")
POLICY=$(awk '/- name: Post ralph-gate status \+ human-approved merge policy/{on=1} on' "$WF")
assert_eq 1 "$([ -n "$STEP" ] && echo 1 || echo 0)" "an Approver verdict step exists"
assert_eq 1 "$(grep -c 'mode=\$(ralph_approver_mode)' <<<"$STEP")" "it reads the mode from the kit"
assert_eq 1 "$(grep -c 'if \[ "\$mode" = off \]; then' <<<"$STEP")" "off returns before any gh call"
assert_eq 0 "$(awk '/if \[ "\$mode" = off \]; then/{on=1} on && /^ *fi$/{exit} on' <<<"$STEP" | grep -c 'gh ')" "the off branch makes no gh call"
assert_eq 0 "$(grep -c 'gh pr merge' <<<"$STEP")" "the approver step never merges"
assert_eq 1 "$(grep -c 'ralph_approver_act "\$mode"' <<<"$STEP")" "it acts through ralph_approver_act"
assert_eq 1 "$(grep -c 'ralph_arm_reason "\$pr_ok" "\$issue_ok" "\${approver_ok:-false}"' <<<"$POLICY")" "the merge policy passes the approver's merge to ralph_arm_reason"
assert_eq 1 "$(grep -c 'steps.approver.outputs.merge_ok' <<<"$POLICY")" "and takes it only from the approver step's output"
HOLD=$(awk '/if \[ "\$\{\{ steps.approver.outputs.hold \}\}" = "true" \]; then/{on=1} on && /^ *fi$/{print; exit} on' <<<"$POLICY")
assert_contains "$HOLD" "issue_ok=false" "an escalation stops ralph-auto from arming"
assert_contains "$HOLD" "RALPH_DEFAULT_AUTO_MERGE=false" "and stops the default posture from arming"
assert_eq 1 "$(grep -c 'echo "hold=true"' <<<"$STEP")" "the approver step sets hold for on + escalate/park"
assert_contains "$(grep -n '"security"' "$WF")" "none" "the reviewer prompt asks for a security severity"

report
