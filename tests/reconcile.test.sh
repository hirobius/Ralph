#!/usr/bin/env bash
# Decision-table tests for reconcile_issue — the loop's single most
# safety-critical decision: "the model iteration finished — what actually
# happened?". It must never (a) count a PR from a PAST run as this run's
# success (the hds#126 restart loop), nor (b) conflate a DELIBERATE
# blocked-stop with a GENUINE failure (the site-engine#86 chain stall). Each
# case builds a GitHub world out of fixtures and asserts the printed token +
# the mutations performed. gh/git are stubbed on PATH — no network.
#
# The run boundary in every case: this run is "run-1", claimed at
# 2026-07-12T10:00:00Z (the ralph-claim comment's server timestamp).
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

CLAIM_AT="2026-07-12T10:00:00Z"

std_claim_comment() {
  fixture api_issue_comments_126.json <<JSON
[{"body": "ralph-claim run-1", "created_at": "$CLAIM_AT"}]
JSON
}

std_state_queued() {
  fixture issue_view_state_126.json <<'JSON'
{"state": "OPEN", "labels": [{"name": "ralph-ready"}, {"name": "p0"}]}
JSON
}

# ralph-ready labeled well before this run — the reset boundary for the
# blocked-sentinel and attempt-budget "since" checks.
std_ready_labeled() {
  fixture api_issue_events_126.json <<'JSON'
[{"event": "labeled", "label": {"name": "ralph-ready"},
  "created_at": "2026-07-09T00:00:00Z"}]
JSON
}

run_reconcile() {
  (cd "$CASE" && bash ralph/lib.sh reconcile_issue 126 run-1 "claude exit 0" 2>>stderr.log)
}

# ── 1. An OPEN PR counts as success no matter when it was created ────────────
new_case open_pr_any_age
std_claim_comment
fixture pr_list_all.json <<'JSON'
[{"number": 171, "headRefName": "ralph/issue-126-modes", "state": "OPEN",
  "createdAt": "2026-07-10T06:00:00Z"}]
JSON
out=$(run_reconcile)
assert_eq "pr:171" "$out" "open PR is this run's success"
assert_mutation "refs/heads/ralph/claim-126" "claim ref released"

# ── 2. A PR merged DURING this run counts as success ─────────────────────────
new_case merged_during_run
std_claim_comment
fixture pr_list_all.json <<'JSON'
[{"number": 172, "headRefName": "ralph/issue-126-contrast", "state": "MERGED",
  "createdAt": "2026-07-12T10:30:00Z"}]
JSON
out=$(run_reconcile)
assert_eq "pr:172" "$out" "fast-merged PR from this run is success"

# ── 3. THE hds#126 BUG: PRs merged in PAST runs are not this run's success ──
new_case merged_before_run_parks
std_claim_comment
std_state_queued
std_ready_labeled
fixture pr_list_all.json <<'JSON'
[{"number": 171, "headRefName": "ralph/issue-126-modes", "state": "MERGED",
  "createdAt": "2026-07-10T06:19:00Z"},
 {"number": 176, "headRefName": "ralph/issue-126-aa", "state": "MERGED",
  "createdAt": "2026-07-12T08:46:00Z"}]
JSON
out=$(run_reconcile)
assert_contains "$out" "parked:" "historical merges do not reconcile as success"
assert_contains "$out" "not agent-actionable" "park reason names the remainder"
assert_mutation "--add-label needs-adrian" "parked to needs-adrian"
assert_no_mutation "ralph-attempt-failed" "no attempt burned on the anomaly"

# ── 4. A human-closed PR parks for direction and is never resurrected ────────
new_case closed_pr_parks
std_claim_comment
std_state_queued
std_ready_labeled
fixture pr_list_all.json <<'JSON'
[{"number": 150, "headRefName": "ralph/issue-126-old", "state": "CLOSED",
  "createdAt": "2026-07-11T12:00:00Z"}]
JSON
printf 'deadbeef\trefs/heads/ralph/issue-126-old\n' >"$GH_FIX_DIR/git_ls_heads.txt"
out=$(run_reconcile)
assert_contains "$out" "parked:" "human-closed PR parks"
assert_mutation "--add-label needs-adrian" "parked to needs-adrian"
assert_no_mutation "pr create" "closed PR's branch is not resurrected"
assert_no_mutation "ralph-attempt-failed" "rejection is not an attempt"

# ── 5. Branch pushed but PR step died → reconcile opens the PR itself ────────
new_case branch_recovery
std_claim_comment
fixture pr_list_all.json <<'JSON'
[]
JSON
printf 'deadbeef\trefs/heads/ralph/issue-126-fresh\n' >"$GH_FIX_DIR/git_ls_heads.txt"
out=$(run_reconcile)
assert_eq "pr:recovered" "$out" "orphan branch recovered into a PR"
assert_mutation "pr create" "PR was opened by reconciliation"

# ── 6. Deliberate stop — issue left the ready queue mid-run (needs-adrian
#      label present) → parked green, no attempt ─────────────────────────────
new_case deliberate_stop_left_queue
std_claim_comment
fixture pr_list_all.json <<'JSON'
[]
JSON
fixture issue_view_state_126.json <<'JSON'
{"state": "OPEN", "labels": [{"name": "ralph-ready"}, {"name": "needs-adrian"}]}
JSON
out=$(run_reconcile)
assert_contains "$out" "left the ready queue" "hand-off via label is a deliberate stop"
assert_no_mutation "ralph-attempt-failed" "no attempt recorded on hand-off"

# ── 6b. Issue closed by a human mid-run → parked green, no attempt ───────────
new_case issue_closed_mid_run
std_claim_comment
fixture pr_list_all.json <<'JSON'
[]
JSON
fixture issue_view_state_126.json <<'JSON'
{"state": "CLOSED", "labels": [{"name": "ralph-ready"}]}
JSON
out=$(run_reconcile)
assert_contains "$out" "parked:" "closed-mid-run is a deliberate stop"
assert_no_mutation "ralph-attempt-failed" "no attempt on a human retraction"

# ── 7. Deliberate blocked-stop via the `ralph-blocked` sentinel comment
#      (#14 / site-engine#86): no label change → routed to needs-adrian, no
#      attempt ─────────────────────────────────────────────────────────────
new_case ralph_blocked_sentinel
std_claim_comment
std_state_queued
std_ready_labeled
fixture pr_list_all.json <<'JSON'
[]
JSON
fixture issue_view_comments_126.json <<'JSON'
{"comments": [{"body": "ralph-blocked: needs a human decision on the schema",
               "createdAt": "2026-07-12T09:59:00Z"}]}
JSON
out=$(run_reconcile)
assert_contains "$out" "ralph-blocked" "sentinel routes to a human"
assert_mutation "--add-label needs-adrian" "parked to needs-adrian"
assert_no_mutation "ralph-attempt-failed" "blocked-stop burns no attempt"

# ── 8. A STALE `ralph-blocked` from before the last re-queue must NOT suppress
#      a genuine failure ─────────────────────────────────────────────────────
new_case stale_ralph_blocked_still_fails
std_claim_comment
std_state_queued
std_ready_labeled
fixture pr_list_all.json <<'JSON'
[]
JSON
fixture issue_view_comments_126.json <<'JSON'
{"comments": [{"body": "ralph-blocked: an old blocker, since resolved",
               "createdAt": "2026-07-08T00:00:00Z"}]}
JSON
out=$(run_reconcile)
assert_contains "$out" "failed:" "stale sentinel does not suppress the failure"
assert_no_mutation "--add-label needs-adrian" "no hand-off on a stale sentinel"

# ── 9. Eligibility check API-dead → conservative attempt, NOT a false
#      deliberate stop (empty jq output must read as "queued") ────────────────
new_case state_api_dead_records_attempt
std_claim_comment
std_ready_labeled
fixture pr_list_all.json <<'JSON'
[]
JSON
fixture issue_view_comments_126.json <<'JSON'
{"comments": []}
JSON
export GH_FAIL_PATTERNS='issue view 126 --json state,labels'
out=$(run_reconcile)
assert_contains "$out" "failed:" "dead state fetch falls through to the attempt path"
assert_mutation "ralph-attempt-failed run-1" "attempt still recorded"

# ── 10. Nothing shipped, still queued → one attempt recorded ─────────────────
new_case first_failure_records_attempt
std_claim_comment
std_state_queued
fixture api_issue_events_126.json <<'JSON'
[{"event": "labeled", "label": {"name": "ralph-ready"},
  "created_at": "2026-07-11T00:00:00Z"}]
JSON
fixture issue_view_comments_126.json <<'JSON'
{"comments": [{"body": "ralph-attempt-failed run-1 — nothing shipped",
               "createdAt": "2026-07-12T10:05:00Z"}]}
JSON
out=$(run_reconcile)
assert_contains "$out" "failed:" "no-ship is a failure"
assert_contains "$out" "attempt 1/2" "attempt counted against the budget"
assert_mutation "ralph-attempt-failed run-1" "attempt comment posted"

# ── 11. Attempt cap reached → parked to ralph-parked ─────────────────────────
new_case cap_parks
std_claim_comment
std_state_queued
fixture api_issue_events_126.json <<'JSON'
[{"event": "labeled", "label": {"name": "ralph-ready"},
  "created_at": "2026-07-11T00:00:00Z"}]
JSON
fixture issue_view_comments_126.json <<'JSON'
{"comments": [{"body": "ralph-attempt-failed run-0 — x",
               "createdAt": "2026-07-12T09:00:00Z"},
              {"body": "ralph-attempt-failed run-1 — y",
               "createdAt": "2026-07-12T10:05:00Z"}]}
JSON
out=$(run_reconcile)
assert_contains "$out" "parked:" "cap parks the issue"
assert_mutation "--add-label ralph-parked" "parked to ralph-parked"

# ── 12. Attempt count unverifiable (API dead) → fail WITHOUT parking ─────────
new_case attempt_count_api_dead
std_claim_comment
std_state_queued
fixture pr_list_all.json <<'JSON'
[]
JSON
fixture api_issue_events_126.json <<'JSON'
[]
JSON
export GH_FAIL_PATTERNS='issue view 126 --json comments'
out=$(run_reconcile)
assert_contains "$out" "failed:" "API-dead count is a plain failure"
assert_contains "$out" "unverifiable" "reason names the blindness"
assert_no_mutation "--add-label ralph-parked" "never park on an unverifiable budget"

# ── 13. Claim comment missing → fallback window still excludes old merges ────
new_case no_claim_comment_fallback
fixture api_issue_comments_126.json <<'JSON'
[]
JSON
std_state_queued
std_ready_labeled
fixture pr_list_all.json <<'JSON'
[{"number": 171, "headRefName": "ralph/issue-126-modes", "state": "MERGED",
  "createdAt": "2026-07-10T06:19:00Z"}]
JSON
out=$(run_reconcile)
assert_contains "$out" "parked:" "day-old merge is not success even without a claim comment"

report
