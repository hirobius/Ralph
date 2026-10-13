#!/usr/bin/env bash
# Approver Phase 1 (ralph#43, engine side of ops#564): ralph_approver_decide
# is a pure decision table. Facts in (key=value lines on stdin), one line out:
# `<merge|escalate|park> <code>`. Each row of the table in #43 is a case
# here; a policy change must show up as a change to this file.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

new_case setup
# shellcheck source=kit/lib.sh
. "$CASE/ralph/lib.sh"

# The all-clear record; each case overrides one or more facts.
CLEAR="gate=green
review=approve
supervised=false
security=none
disagree=false
approver=off"

decide() { # [key=value ...] — CLEAR with overrides applied
  local facts="$CLEAR" kv
  for kv in "$@"; do
    facts=$(grep -v "^${kv%%=*}=" <<<"$facts")
    facts="$facts"$'\n'"$kv"
  done
  ralph_approver_decide <<<"$facts"
}

row() { # <expected> <label> [key=value ...]
  local want=$1 label=$2
  shift 2
  CASE_NAME=row
  assert_eq "$want" "$(decide "$@")" "$label"
}

# ── the table, first match wins ─────────────────────────────────────────
row "park gate-red"                    "1 red gate parks"                 gate=red
row "park gate-red"                    "1 red gate beats a supervised diff" gate=red supervised=true
row "park gate-red"                    "1 red gate parks even with unreadable facts" gate=red review=maybe
row "escalate unreadable-facts"        "2 unknown value"                  review=maybe
row "escalate unreadable-facts"        "2 unknown gate value"             gate=amber
row "escalate rework-exhausted"        "3 changes still requested"        review=request_changes
row "escalate no-review"               "4 reviewer produced no verdict"   review=none
row "escalate supervised-path"         "5 supervised diff"                supervised=true
row "escalate supervised-path"         "5 unreadable boundary"            supervised=unknown
row "escalate security-finding"        "6 high"                           security=high
row "escalate security-finding"        "6 critical"                       security=critical
row "escalate security-finding"        "6 unknown severity"               security=unknown
row "merge policy-clear"               "6 low merges (ADR-009)"           security=low
row "merge policy-clear"               "6 medium merges (ADR-009)"        security=medium
row "escalate reviewer-disagreement"   "7 reviewers disagree"             disagree=true
row "escalate approver-unavailable"    "8 approver errored"               approver=error
row "escalate approver-unavailable"    "8 approver rate-limited"          approver=rate_limited
row "escalate approver-unavailable"    "8 approver wrote nothing"         approver=empty
row "escalate approver-unavailable"    "8 ok without a verdict"           approver=ok
row "escalate approver-unavailable"    "8 ok with a bad verdict"          approver=ok approver_verdict=yes
row "escalate approver-escalated"      "9 approver says escalate"         approver=ok approver_verdict=escalate
row "merge policy-clear"               "10 approver says merge"           approver=ok approver_verdict=merge
row "merge policy-clear"               "10 all clear, approver off"
row "merge policy-clear"               "10 a stray verdict is ignored when off" approver_verdict=escalate

# ── precedence between escalations: the earliest row names the cause ───
row "escalate rework-exhausted"        "3 before 5"                       review=request_changes supervised=true
row "escalate supervised-path"         "5 before 6"                       supervised=true security=critical
row "escalate security-finding"        "6 before 8"                       security=high approver=error
row "escalate supervised-path"         "a model merge never clears a code escalation" supervised=true approver=ok approver_verdict=merge

# ── input hygiene ──────────────────────────────────────────────────────
new_case missing_fact
assert_eq "escalate unreadable-facts" "$(grep -v '^security=' <<<"$CLEAR" | ralph_approver_decide)" "a missing fact escalates"

new_case empty_input
assert_eq "escalate unreadable-facts" "$(ralph_approver_decide </dev/null)" "empty stdin escalates"

new_case duplicate_key
assert_eq "escalate unreadable-facts" "$(printf '%s\nsupervised=true\n' "$CLEAR" | ralph_approver_decide)" \
  "a key given twice is unreadable, not last-wins"

new_case extra_keys_ignored
assert_eq "merge policy-clear" "$(printf '%s\npr=12\nnote=anything\n' "$CLEAR" | ralph_approver_decide)" \
  "unknown extra keys are ignored"

new_case crlf_and_spaces
assert_eq "escalate supervised-path" \
  "$(sed 's/supervised=false/  supervised = true  /; s/$/\r/' <<<"$CLEAR" | ralph_approver_decide)" \
  "CRLF and spaces around keys and values are stripped"

new_case blank_and_comment_lines
assert_eq "merge policy-clear" "$(printf '\n# a comment\n%s\n\n' "$CLEAR" | ralph_approver_decide)" \
  "blank lines and # comments are skipped"

new_case always_exit_zero
ralph_approver_decide </dev/null >/dev/null
assert_eq 0 "$?" "a decision is always printed with exit 0"

# ── every code has a sentence for the PR/issue comment ─────────────────
new_case reasons
for code in gate-red unreadable-facts rework-exhausted no-review supervised-path \
  security-finding reviewer-disagreement approver-unavailable approver-escalated policy-clear; do
  r=$(ralph_approver_reason "$code")
  if [ -n "$r" ]; then _ok "$code has a reason"; else _fail "$code has no reason"; fi
done
assert_eq "" "$(ralph_approver_reason nonsense)" "an unknown code has no reason"

report
