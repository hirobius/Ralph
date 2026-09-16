#!/usr/bin/env bash
# Attempt-accounting tests for the selector's budget guard (ops#303).
#
# THE BUG THESE PIN DOWN. `count_failed_attempts` counts `ralph-attempt-failed`
# comments created AFTER a boundary, and that boundary is `latest_ready_label_at`
# — the timestamp of the MOST RECENT `ralph-ready` labeling. So re-queuing an
# issue moves the boundary past every prior failure and resets the count to zero.
# RALPH_MAX_ATTEMPTS is therefore a per-queueing cap, never a lifetime one: an
# issue can fail twice, park, be re-queued, fail twice more, forever, looking
# clean to the selector each cycle.
#
# Observed live in ops on 2026-09-16: ops#44 carried two attempt-failed comments
# from July, was re-labeled `ralph-ready`, and the selector read its budget as 0.
#
# WHY THE OBVIOUS FIX IS WRONG. You cannot simply stop moving the boundary. The
# PR-history guard directly above this one in next.sh depends on it — re-adding
# the ready label is how a human says "I looked at the merged PR, try again", and
# that must clear a stale merged/closed verdict. next.sh says so in a comment.
# One boundary is serving two guards with opposite needs. History must reset on
# re-label; the failure counter must not.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

run_next() { # captures stdout; exit code lands in NEXT_CODE
  # Env set as a prefix (RALPH_MAX_LIFETIME_ATTEMPTS=2 run_next) reaches next.sh
  # because the subshell inherits it — that is how a case tightens a cap.
  NEXT_CODE=0
  (cd "$CASE" && bash ralph/next.sh 2>>stderr.log) || NEXT_CODE=$?
}

issue_200_ready() {
  fixture issue_list.json <<'JSON'
[{"number": 200, "labels": [{"name": "ralph-ready"}, {"name": "p2"}],
  "body": "## DoD\n- [ ] the thing works"}]
JSON
  # No prior Ralph PRs: isolates the budget guard from the history guard.
  fixture pr_list_all.json <<'JSON'
[]
JSON
}

# ── 1. Unbounded thrash across re-queuings must eventually stop ─────────────
# Five failures spread over two queueings, then a fresh ralph-ready. Every
# failure predates the boundary, so the per-cycle counter reads 0 and the issue
# is selected again — forever. This is the ops#156 shape (12+ re-claims over
# ~12 hours). The LIFETIME cap is what bounds it.
new_case attempts_lifetime_cap_stops_thrash
issue_200_ready
fixture api_issue_events_200.json <<'JSON'
[{"event": "labeled", "label": {"name": "ralph-ready"},
  "created_at": "2026-07-11T00:00:00Z"},
 {"event": "labeled", "label": {"name": "ralph-ready"},
  "created_at": "2026-09-16T07:03:00Z"}]
JSON
fixture issue_view_comments_200.json <<'JSON'
{"comments": [
  {"body": "ralph-attempt-failed ci-1", "createdAt": "2026-07-11T00:10:00Z"},
  {"body": "ralph-attempt-failed ci-2", "createdAt": "2026-07-11T00:20:00Z"},
  {"body": "ralph-attempt-failed ci-3", "createdAt": "2026-07-11T00:30:00Z"},
  {"body": "ralph-attempt-failed ci-4", "createdAt": "2026-07-11T00:40:00Z"},
  {"body": "ralph-attempt-failed ci-5", "createdAt": "2026-07-11T00:50:00Z"}
]}
JSON
run_next
assert_eq 10 "$NEXT_CODE" "lifetime cap stops thrash a re-queue would otherwise reset"
assert_mutation "--add-label ralph-parked" "parked on the lifetime cap"

# ── 2. THE ops#44 SHAPE: a deliberate re-queue after a couple of failures ───
# Two July failures, re-queued in September. This MUST stay selectable. The
# learned rules record that "iteration ended without a pushed branch" is usually
# loop infrastructure or an ask-don't-guess stop, not a bad issue — ops#303's
# own table lists ops#44 as exactly that. A lifetime cap set low enough to block
# this would punish issues for the loop's own defects, which is why the lifetime
# cap is deliberately HIGHER than the per-cycle cap.
new_case attempts_deliberate_requeue_still_runs
issue_200_ready
fixture api_issue_events_200.json <<'JSON'
[{"event": "labeled", "label": {"name": "ralph-ready"},
  "created_at": "2026-09-16T07:03:00Z"}]
JSON
fixture issue_view_comments_200.json <<'JSON'
{"comments": [
  {"body": "ralph-attempt-failed ci-1", "createdAt": "2026-07-11T00:59:48Z"},
  {"body": "ralph-attempt-failed ci-2", "createdAt": "2026-07-11T01:31:57Z"}
]}
JSON
run_next
assert_eq 0 "$NEXT_CODE" "a deliberate re-queue after 2 failures still runs"

# ── 2b. PROVES the count is actually pre-boundary, not just permissive ──────
# Case 2 alone is vacuous: an implementation that always returned 0 would pass
# it, because 0 is also under the cap. Same fixture, cap tightened to 2 — now
# only an implementation that genuinely counts the two PRE-boundary failures
# can park. Verified by mutation: stubbing the lifetime count to 0 fails this
# case and leaves case 2 green.
new_case attempts_counts_pre_boundary_failures
issue_200_ready
fixture api_issue_events_200.json <<'JSON'
[{"event": "labeled", "label": {"name": "ralph-ready"},
  "created_at": "2026-09-16T07:03:00Z"}]
JSON
fixture issue_view_comments_200.json <<'JSON'
{"comments": [
  {"body": "ralph-attempt-failed ci-1", "createdAt": "2026-07-11T00:59:48Z"},
  {"body": "ralph-attempt-failed ci-2", "createdAt": "2026-07-11T01:31:57Z"}
]}
JSON
RALPH_MAX_LIFETIME_ATTEMPTS=2 run_next
assert_eq 10 "$NEXT_CODE" "pre-boundary failures are counted, not read as 0"
assert_mutation "--add-label ralph-parked" "parks on a pre-boundary lifetime count"

# ── 3. A clean issue is unaffected ──────────────────────────────────────────
new_case attempts_clean_issue_selectable
issue_200_ready
fixture api_issue_events_200.json <<'JSON'
[{"event": "labeled", "label": {"name": "ralph-ready"},
  "created_at": "2026-09-16T07:03:00Z"}]
JSON
fixture issue_view_comments_200.json <<'JSON'
{"comments": []}
JSON
run_next
assert_eq 0 "$NEXT_CODE" "an issue with no failures is selectable"

# ── 4. API blindness still fails CLOSED ─────────────────────────────────────
# An unreadable comment feed must skip, never park and never select. A budget
# guard that guesses is worse than one that abstains.
new_case attempts_api_failure_fails_closed
issue_200_ready
fixture api_issue_events_200.json <<'JSON'
[{"event": "labeled", "label": {"name": "ralph-ready"},
  "created_at": "2026-09-16T07:03:00Z"}]
JSON
export GH_FAIL_PATTERNS='issue view .*--json comments'
run_next
assert_eq 10 "$NEXT_CODE" "unreadable comments skip the candidate"
assert_no_mutation "--add-label ralph-parked" "fails closed: skip, never park"

# ── 5. The PER-CYCLE cap still fires, unchanged ─────────────────────────────
# Two failures AFTER the latest labeling: this cycle has spent its budget. The
# lifetime counter must not replace this guard, only sit behind it.
new_case attempts_per_cycle_cap_unchanged
issue_200_ready
fixture api_issue_events_200.json <<'JSON'
[{"event": "labeled", "label": {"name": "ralph-ready"},
  "created_at": "2026-09-16T07:00:00Z"}]
JSON
fixture issue_view_comments_200.json <<'JSON'
{"comments": [
  {"body": "ralph-attempt-failed ci-a", "createdAt": "2026-09-16T08:00:00Z"},
  {"body": "ralph-attempt-failed ci-b", "createdAt": "2026-09-16T09:00:00Z"}
]}
JSON
run_next
assert_eq 10 "$NEXT_CODE" "per-cycle cap still parks within one queueing"
assert_mutation "--add-label ralph-parked" "per-cycle park unchanged"

report
