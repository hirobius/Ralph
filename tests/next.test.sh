#!/usr/bin/env bash
# Decision-table tests for next.sh — the deterministic selector. The new
# PR-history guard must park (not re-offer) issues whose last queue-cycle
# already ended in a merge or a human rejection, and every API blindness must
# fail closed (skip, never park, never select).
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

run_next() { # captures stdout; exit code lands in NEXT_CODE
  NEXT_CODE=0
  (cd "$CASE" && bash ralph/next.sh 2>>stderr.log) || NEXT_CODE=$?
}

issue_126_ready() {
  fixture issue_list.json <<'JSON'
[{"number": 126, "labels": [{"name": "ralph-ready"}, {"name": "p0"}],
  "body": "## DoD\n- [ ] snapshots exist\n- [ ] gate green"}]
JSON
}

# ── 1. Merged PR newer than the last ralph-ready labeling → park, not re-run ─
new_case history_merged_parks
issue_126_ready
fixture pr_list_all.json <<'JSON'
[{"headRefName": "ralph/issue-126-aa", "state": "MERGED",
  "mergedAt": "2026-07-12T09:21:00Z", "closedAt": "2026-07-12T09:21:00Z"}]
JSON
fixture api_issue_events_126.json <<'JSON'
[{"event": "labeled", "label": {"name": "ralph-ready"},
  "created_at": "2026-07-09T06:00:00Z"}]
JSON
run_next
assert_eq 10 "$NEXT_CODE" "queue exhausts instead of re-offering #126"
assert_mutation "--add-label needs-adrian" "parked to needs-adrian"
assert_mutation "--remove-label ralph-ready" "pulled from the queue"

# ── 2. Human-closed PR newer than the labeling → park for direction ──────────
new_case history_closed_parks
issue_126_ready
fixture pr_list_all.json <<'JSON'
[{"headRefName": "ralph/issue-126-x", "state": "CLOSED",
  "mergedAt": null, "closedAt": "2026-07-12T08:00:00Z"}]
JSON
fixture api_issue_events_126.json <<'JSON'
[{"event": "labeled", "label": {"name": "ralph-ready"},
  "created_at": "2026-07-09T06:00:00Z"}]
JSON
run_next
assert_eq 10 "$NEXT_CODE" "rejected work is not silently retried"
assert_mutation "--add-label needs-adrian" "parked to needs-adrian"

# ── 3. Re-adding ralph-ready AFTER the merge is a deliberate re-queue ─────────
new_case relabel_resets_history
issue_126_ready
fixture pr_list_all.json <<'JSON'
[{"headRefName": "ralph/issue-126-aa", "state": "MERGED",
  "mergedAt": "2026-07-10T09:21:00Z", "closedAt": "2026-07-10T09:21:00Z"}]
JSON
fixture api_issue_events_126.json <<'JSON'
[{"event": "labeled", "label": {"name": "ralph-ready"},
  "created_at": "2026-07-12T12:00:00Z"}]
JSON
fixture issue_view_comments_126.json <<'JSON'
{"comments": []}
JSON
sel=$(cd "$CASE" && bash ralph/next.sh 2>>"$CASE/stderr.log")
assert_eq "126" "$sel" "re-labeled issue is offered again"
assert_no_mutation "--add-label needs-adrian" "no park on a deliberate re-queue"

# ── 4. Attempt budget unverifiable → skip the candidate, never park it ───────
new_case unknown_budget_skips
issue_126_ready
fixture pr_list_all.json <<'JSON'
[]
JSON
fixture api_issue_events_126.json <<'JSON'
[]
JSON
export GH_FAIL_PATTERNS='issue view 126 --json comments'
run_next
assert_eq 10 "$NEXT_CODE" "blind budget exhausts the queue"
assert_no_mutation "--add-label" "no label mutation on an API blindness"

# ── 5. Label events unverifiable → skip the candidate, never park it ─────────
new_case unknown_events_skips
issue_126_ready
fixture pr_list_all.json <<'JSON'
[{"headRefName": "ralph/issue-126-aa", "state": "MERGED",
  "mergedAt": "2026-07-10T09:21:00Z", "closedAt": "2026-07-10T09:21:00Z"}]
JSON
export GH_FAIL_PATTERNS='issues/126/events'
run_next
assert_eq 10 "$NEXT_CODE" "blind history exhausts the queue"
assert_no_mutation "--add-label" "no park when the boundary is unknowable"

# ── 6. stdout stays number-only while earlier candidates get parked ──────────
new_case stdout_purity
fixture issue_list.json <<'JSON'
[{"number": 5, "labels": [{"name": "ralph-ready"}, {"name": "p0"}],
  "body": "fix stuff, you know the stuff"},
 {"number": 7, "labels": [{"name": "ralph-ready"}, {"name": "p1"}],
  "body": "## Acceptance\n- [ ] the thing works"}]
JSON
fixture pr_list_all.json <<'JSON'
[]
JSON
fixture api_issue_events_7.json <<'JSON'
[{"event": "labeled", "label": {"name": "ralph-ready"},
  "created_at": "2026-07-09T06:00:00Z"}]
JSON
fixture issue_view_comments_7.json <<'JSON'
{"comments": []}
JSON
sel=$(cd "$CASE" && bash ralph/next.sh 2>>"$CASE/stderr.log")
assert_eq "7" "$sel" "stdout is exactly the selected number"
assert_mutation "issue edit 5" "spec-less #5 was parked on the way"

report
