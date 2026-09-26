#!/usr/bin/env bash
# Decision-table tests for ralph#17's double-claim dedupe: recent_claim_within
# (kit/lib.sh) and its wiring into next.sh's selector. gh is stubbed — no
# network.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

# <n> seconds before "now" as an ISO-8601 Zulu timestamp (GNU/BSD, mirrors
# lib.sh's own epoch_of/iso_of dance so ages line up with what it computes).
ago() {
  local t=$(($(date -u +%s) - $1))
  date -u -d "@$t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$t" +%Y-%m-%dT%H:%M:%SZ
}

wip_fixture() { # <createdAt> — one ralph-wip issue with one ralph-claim comment
  fixture issue_list_wip.json <<JSON
[{"number": 999, "comments": [{"body": "ralph-claim ci-42", "createdAt": "$1"}]}]
JSON
}

run_lib() { bash -c "cd '$CASE' && . ralph/lib.sh && $*"; }

# ── unit: recent_claim_within ────────────────────────────────────────────────

new_case recent_claim_hit
wip_fixture "$(ago 15)"
if run_lib "recent_claim_within 60"; then _ok "15s-old claim is within a 60s window"; else _fail "15s-old claim is within a 60s window"; fi

new_case recent_claim_miss_too_old
wip_fixture "$(ago 300)"
if run_lib "recent_claim_within 60"; then _fail "300s-old claim must not read as recent"; else _ok "300s-old claim must not read as recent"; fi

new_case recent_claim_miss_no_wip_issues
fixture issue_list_wip.json <<'JSON'
[]
JSON
if run_lib "recent_claim_within 60"; then _fail "no ralph-wip issues -> no dedupe"; else _ok "no ralph-wip issues -> no dedupe"; fi

new_case recent_claim_miss_no_claim_comment
fixture issue_list_wip.json <<'JSON'
[{"number": 999, "comments": [{"body": "just chatting", "createdAt": "2026-09-26T00:00:00Z"}]}]
JSON
if run_lib "recent_claim_within 60"; then _fail "no ralph-claim comment present -> no dedupe"; else _ok "no ralph-claim comment present -> no dedupe"; fi

new_case recent_claim_fails_open_on_api_error
export GH_FAIL_PATTERNS='issue list'
if run_lib "recent_claim_within 60"; then _fail "an API failure must fail OPEN (no false dedupe)"; else _ok "an API failure must fail OPEN (no false dedupe)"; fi
unset GH_FAIL_PATTERNS

# ── integration: next.sh only applies the dedupe on push / blank dispatch ──

run_next() { # captures stdout; exit code lands in NEXT_CODE
  NEXT_CODE=0
  (cd "$CASE" && bash ralph/next.sh 2>>stderr.log) || NEXT_CODE=$?
}

ready_issue_126() {
  fixture issue_list.json <<'JSON'
[{"number": 126, "labels": [{"name": "ralph-ready"}, {"name": "p0"}],
  "body": "## DoD\n- [ ] snapshots exist\n- [ ] gate green"}]
JSON
  fixture pr_list_all.json <<'JSON'
[]
JSON
  fixture api_issue_events_126.json <<'JSON'
[{"event": "labeled", "label": {"name": "ralph-ready"},
  "created_at": "2026-07-09T06:00:00Z"}]
JSON
  fixture issue_view_comments_126.json <<'JSON'
{"comments": []}
JSON
}

new_case push_with_recent_claim_skips
ready_issue_126
wip_fixture "$(ago 10)"
export GITHUB_EVENT_NAME=push
run_next
assert_eq 10 "$NEXT_CODE" "push event skips cleanly on a recent ralph-claim"
assert_no_mutation "issue edit 126" "no claim/label mutation on #126 — the double-fire never touched it"
unset GITHUB_EVENT_NAME

new_case dispatch_blank_with_recent_claim_skips
ready_issue_126
wip_fixture "$(ago 10)"
export GITHUB_EVENT_NAME=workflow_dispatch
export ISSUE_INPUT=""
run_next
assert_eq 10 "$NEXT_CODE" "blank-issue workflow_dispatch (the chain hop) skips on a recent ralph-claim"
unset GITHUB_EVENT_NAME ISSUE_INPUT

new_case dispatch_explicit_issue_ignores_dedupe
ready_issue_126
wip_fixture "$(ago 10)"
export GITHUB_EVENT_NAME=workflow_dispatch
export ISSUE_INPUT=126
sel=$(cd "$CASE" && bash ralph/next.sh 2>>"$CASE/stderr.log")
assert_eq "126" "$sel" "an explicit dispatch issue number is never deduped by next.sh"
unset GITHUB_EVENT_NAME ISSUE_INPUT

new_case labeled_event_ignores_dedupe
ready_issue_126
wip_fixture "$(ago 10)"
export GITHUB_EVENT_NAME=issues
sel=$(cd "$CASE" && bash ralph/next.sh 2>>"$CASE/stderr.log")
assert_eq "126" "$sel" "a ralph-ready label event is never suppressed by the double-claim dedupe"
unset GITHUB_EVENT_NAME

new_case schedule_tick_ignores_dedupe
ready_issue_126
wip_fixture "$(ago 10)"
export GITHUB_EVENT_NAME=schedule
sel=$(cd "$CASE" && bash ralph/next.sh 2>>"$CASE/stderr.log")
assert_eq "126" "$sel" "the idle-watchdog schedule tick is never suppressed by the double-claim dedupe"
unset GITHUB_EVENT_NAME

new_case push_with_old_claim_selects_normally
ready_issue_126
wip_fixture "$(ago 300)"
export GITHUB_EVENT_NAME=push
sel=$(cd "$CASE" && bash ralph/next.sh 2>>"$CASE/stderr.log")
assert_eq "126" "$sel" "a stale ralph-claim (outside the window) never blocks a genuine push trigger"
unset GITHUB_EVENT_NAME

report
