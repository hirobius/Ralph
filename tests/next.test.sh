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

# ── 7-12. `## Blocked by` frontier selection (ops#474) ───────────────────────
# A candidate with an OPEN blocker is skipped (logged, no park, no attempt
# burned); an unreadable blocker fails closed. Helpers keep the cases terse.
blocked_world() { # <issue-body> — one ralph-ready #20 plus the clean-history fixtures
  fixture issue_list.json <<JSON
[{"number": 20, "labels": [{"name": "ralph-ready"}],
  "body": "$1"}]
JSON
  fixture pr_list_all.json <<'JSON'
[]
JSON
  fixture api_issue_events_20.json <<'JSON'
[{"event": "labeled", "label": {"name": "ralph-ready"},
  "created_at": "2026-07-09T06:00:00Z"}]
JSON
  fixture issue_view_comments_20.json <<'JSON'
{"comments": []}
JSON
}
blocker_state() { fixture "issue_view_state_$1.json" <<<"{\"state\": \"$2\"}"; }
pick() { sel=$(cd "$CASE" && bash ralph/next.sh 2>>"$CASE/stderr.log"); NEXT_CODE=$?; }

new_case blocked_no_section
blocked_world '## DoD\n- [ ] done'
pick
assert_eq "20" "$sel" "no Blocked by section → picked"

new_case blocked_none
blocked_world '## DoD\n- [ ] done\n\n## Blocked by\n\nNone (can start immediately)\n\n## Notes\nsee #99'
pick
assert_eq "20" "$sel" "\"None (can start immediately)\" → picked"

new_case blocked_all_closed
blocked_world '## DoD\n- [ ] done\n\n## Blocked by\n\n- #12 — schema\n- #13\n\n## Notes\nsee #99'
blocker_state 12 CLOSED
blocker_state 13 CLOSED
pick
assert_eq "20" "$sel" "all blockers closed → picked (list refs with trailing text)"
assert_no_mutation "--add-label" "no park"

new_case blocked_one_open
blocked_world '## DoD\n- [ ] done\n\n## Blocked by\n\n- #12 — schema\n- #13'
blocker_state 12 CLOSED
blocker_state 13 OPEN
pick
assert_eq "" "$sel" "open blocker → stdout untouched"
assert_eq 10 "$NEXT_CODE" "queue exhausted, not failed"
assert_contains "$(cat "$CASE/stderr.log")" "ralph: #20 blocked by #13 (open) — skipping" "skip is logged"
assert_no_mutation "gh issue" "no park, no comment, no attempt burned"

new_case blocked_open_next_picked
fixture issue_list.json <<'JSON'
[{"number": 20, "labels": [{"name": "ralph-ready"}, {"name": "p0"}],
  "body": "## DoD\n- [ ] a\n\n## Blocked by\n\n- #12"},
 {"number": 21, "labels": [{"name": "ralph-ready"}, {"name": "p1"}],
  "body": "## DoD\n- [ ] b\n\n## Blocked by\n\nNone"}]
JSON
fixture pr_list_all.json <<'JSON'
[]
JSON
fixture api_issue_events_21.json <<'JSON'
[{"event": "labeled", "label": {"name": "ralph-ready"},
  "created_at": "2026-07-09T06:00:00Z"}]
JSON
fixture issue_view_comments_21.json <<'JSON'
{"comments": []}
JSON
blocker_state 12 OPEN
pick
assert_eq "21" "$sel" "next candidate picked past the blocked one"
assert_no_mutation "--add-label" "blocked candidate not parked"

new_case blocked_unreadable
blocked_world '## DoD\n- [ ] done\n\n## Blocked by\n\n- #12'
export GH_FAIL_PATTERNS='issue view 12 '
pick
assert_eq "" "$sel" "unreadable blocker → not picked"
assert_eq 10 "$NEXT_CODE" "fails closed to queue-empty"
assert_no_mutation "--add-label" "unreadable blocker never parks"

report
