#!/usr/bin/env bash
# Fallback blocked-stop inference (ops#303, the PRIMARY half).
#
# THE GAP. reconcile_issue already routes a deliberate stop to a human without
# charging an attempt — but only when the model prefixes a comment with the
# `ralph-blocked` sentinel. ops#303: "A load-bearing protocol rides entirely on
# the model remembering a string prefix, with no fallback." It failed exactly
# that way on ops#39 and ops#44: the agent wrote a clear prose explanation of
# why it was stopping, just not starting with the sentinel, and was charged an
# attempt for following CLAUDE.md's own ask-don't-guess rule.
#
# THE INFERENCE. An iteration that pushed no branch BUT left a substantive
# comment of its own this cycle is a deliberate stop, not a crash.
#
# WHY THIS CANNOT LOOP. The inference PARKS (to needs-adrian, pulling
# `ralph-ready`) rather than retrying. So even a false positive — a genuine
# crash that happened to post a long comment — halts for a human instead of
# spinning. That property is load-bearing: no attempt is recorded on this path,
# so neither the per-cycle nor the lifetime cap would bound a retry loop if one
# could occur. A test below pins the park behaviour open for that reason.
#
# WHAT MUST NOT TRIGGER IT. Harness-authored comments (`ralph-claim`,
# `ralph-attempt-failed`, the park notices) are not the model speaking, and a
# comment from a PREVIOUS cycle is not evidence about this one.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

CLAIM_AT="2026-07-12T09:00:00Z"

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

std_ready_labeled() {
  fixture api_issue_events_126.json <<'JSON'
[{"event": "labeled", "label": {"name": "ralph-ready"},
  "created_at": "2026-07-09T00:00:00Z"}]
JSON
}

no_prs() {
  fixture pr_list_all.json <<'JSON'
[]
JSON
}

run_reconcile() {
  (cd "$CASE" && bash ralph/lib.sh reconcile_issue 126 run-1 "claude exit 0" 2>>stderr.log)
}

# ── 1. THE ops#39 / ops#44 SHAPE: substantive comment, no sentinel ──────────
new_case inferred_blocked_stop_burns_no_attempt
std_claim_comment
std_state_queued
std_ready_labeled
no_prs
fixture issue_view_comments_126.json <<'JSON'
{"comments": [{"body": "I checked this against main and most of the DoD has already shipped in PR #162. The remaining item is a billing-adjacent auto-flip, and I am not going to guess at that without a decision from Adrian. Stopping here rather than building the wrong thing.",
               "createdAt": "2026-07-12T09:59:00Z"}]}
JSON
out=$(run_reconcile)
assert_mutation "--add-label needs-adrian" "inferred blocked-stop routes to a human"
assert_no_mutation "ralph-attempt-failed" "an ask-don't-guess stop burns no attempt"
assert_contains "$out" "parked" "reported as a park, not a failure"

# ── 2. It PARKS — it must never leave the issue queued for a retry ──────────
# No attempt is recorded on this path, so nothing would bound a retry loop.
# Pulling the ready label is what makes a false positive safe.
new_case inferred_blocked_stop_leaves_the_queue
std_claim_comment
std_state_queued
std_ready_labeled
no_prs
fixture issue_view_comments_126.json <<'JSON'
{"comments": [{"body": "This needs a schema decision I cannot make autonomously. The two options each lose information, so I am stopping and asking rather than picking one silently.",
               "createdAt": "2026-07-12T09:59:00Z"}]}
JSON
run_reconcile >/dev/null
assert_mutation "--remove-label ralph-ready" "pulled from the queue, cannot spin"

# ── 3. Harness comments are NOT the model speaking ──────────────────────────
# `ralph-claim` and `ralph-attempt-failed` are written by the loop itself. If
# they counted as evidence, EVERY failure would look deliberate and the attempt
# budget would stop working entirely.
new_case harness_comments_do_not_infer
std_claim_comment
std_state_queued
std_ready_labeled
no_prs
# These are LONG on purpose. Short harness comments would be filtered by the
# length floor alone, leaving the authorship exclusion untested — verified by
# mutation: with short fixtures, deleting the `^ralph-` filter broke nothing.
fixture issue_view_comments_126.json <<'JSON'
{"comments": [
  {"body": "ralph-attempt-failed run-0 — iteration ended without a pushed branch (claude step outcome: failure). The agent produced no branch this cycle and the harness recorded the attempt against the per-cycle budget as usual.",
   "createdAt": "2026-07-12T09:30:00Z"},
  {"body": "🅿️ **Ralph parked this issue** — hit the attempt cap (2/2 failed attempts — see the ralph-attempt-failed comments above).\n(To retry: fix the cause, then re-add `ralph-ready`.)",
   "createdAt": "2026-07-12T09:35:00Z"}
]}
JSON
run_reconcile >/dev/null
assert_mutation "ralph-attempt-failed" "a genuine crash still records an attempt"
assert_no_mutation "--add-label needs-adrian" "harness noise does not route to a human"

# ── 4. A STALE comment from a previous cycle must not suppress a failure ────
# Same rule the sentinel already follows: evidence is gated to THIS cycle.
new_case stale_comment_does_not_infer
std_claim_comment
std_state_queued
fixture api_issue_events_126.json <<'JSON'
[{"event": "labeled", "label": {"name": "ralph-ready"},
  "created_at": "2026-07-12T08:00:00Z"}]
JSON
no_prs
fixture issue_view_comments_126.json <<'JSON'
{"comments": [{"body": "An older explanation of why I stopped, written during a previous queueing of this issue and long before the current one began.",
               "createdAt": "2026-07-09T10:00:00Z"}]}
JSON
run_reconcile >/dev/null
assert_mutation "ralph-attempt-failed" "a pre-boundary comment is not evidence about this cycle"

# ── 5. A bare crash with no comment at all is still a failure ───────────────
new_case silent_crash_still_fails
std_claim_comment
std_state_queued
std_ready_labeled
no_prs
fixture issue_view_comments_126.json <<'JSON'
{"comments": []}
JSON
run_reconcile >/dev/null
assert_mutation "ralph-attempt-failed" "no comment, no inference — a crash is a crash"

# ── 6. A terse comment is not a substantive one ─────────────────────────────
# Guards against a one-word or emoji comment reading as a reasoned stop.
new_case terse_comment_does_not_infer
std_claim_comment
std_state_queued
std_ready_labeled
no_prs
fixture issue_view_comments_126.json <<'JSON'
{"comments": [{"body": "working on it", "createdAt": "2026-07-12T09:59:00Z"}]}
JSON
run_reconcile >/dev/null
assert_mutation "ralph-attempt-failed" "a terse note is not a reasoned stop"

report
