#!/usr/bin/env bash
# Decision-table tests for classify_wedged (ralph#16) — the single-flight
# wedge check must tell "gate is running" from "gate died/never started"
# WITHOUT waiting on the flat 3h age fallback, since that blind spot stalled
# the whole queue silently for up to 3h. gh is stubbed on PATH — no network.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# <n> seconds before "now" as an ISO-8601 Zulu timestamp (GNU/BSD, mirrors
# lib.sh's own epoch_of/iso_of dance so ages line up with what it computes).
ago() {
  local t=$(($(date -u +%s) - $1))
  date -u -d "@$t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$t" +%Y-%m-%dT%H:%M:%SZ
}

run_classify() { # <pr-json on stdin>
  (cd "$CASE" && bash ralph/lib.sh classify_wedged)
}

one_pr() { # <n> <sha> <updatedAt> -> open_ralph_prs-shaped JSON for one PR
  cat <<JSON
[{"number": $1, "headRefName": "ralph/issue-$1-x", "headRefOid": "$2", "updatedAt": "$3"}]
JSON
}

# The posted ralph-gate commit status (repos/.../commits/<sha>/status).
# Empty state -> gate never posted anything ("none").
status_fixture() { # <sha> <state|empty>
  local body="[]"
  if [ -n "$2" ]; then
    body="[{\"context\":\"ralph-gate\",\"state\":\"$2\",\"created_at\":\"2026-09-26T11:00:00Z\"}]"
  fi
  fixture "commit_status_$1.json" <<JSON
{"statuses": $body}
JSON
}

# gh run list --workflow ralph-gate.yml --commit <sha> --json status,createdAt
run_fixture() { # <sha> <runs-json-array>
  fixture "run_list_$1.json" <<JSON
$2
JSON
}

# ── 1. success gate: always healthy, run-lookup never needed ───────────────
new_case success_gate_healthy
status_fixture sha1 success
out=$(one_pr 1 sha1 "$NOW" | run_classify)
assert_eq "" "$out" "success gate is healthy"

# ── 2. failure gate: always wedged, needs a human ───────────────────────────
new_case failure_gate_wedged
status_fixture sha2 failure
out=$(one_pr 2 sha2 "$NOW" | run_classify)
assert_contains "$out" "#2" "failed gate flags the PR"
assert_contains "$out" "FAILED" "reason names the failed gate"

# ── 3. gate none, run in_progress: healthy in-flight regardless of age ─────
new_case none_gate_run_in_progress_healthy
status_fixture sha3 ""
run_fixture sha3 '[{"status":"in_progress","createdAt":"2026-09-26T11:58:00Z"}]'
old="$(ago $((36*3600)))" # 36h old — would trip the 3h fallback if reached
out=$(one_pr 3 sha3 "$old" | run_classify)
assert_eq "" "$out" "in_progress run reads as healthy even on an old PR"

# ── 4. gate pending, run queued: healthy ────────────────────────────────────
new_case pending_gate_run_queued_healthy
status_fixture sha4 pending
run_fixture sha4 '[{"status":"queued","createdAt":"2026-09-26T11:59:00Z"}]'
out=$(one_pr 4 sha4 "$NOW" | run_classify)
assert_eq "" "$out" "queued run reads as healthy"

# ── 5. gate none, NO run at all, PR >= grace (10m): wedged NOW, not at 3h ──
new_case no_run_past_grace_wedged
status_fixture sha5 ""
run_fixture sha5 '[]'
past_grace="$(ago $((15*60)))" # 15 minutes old
out=$(one_pr 5 sha5 "$past_grace" | run_classify)
assert_contains "$out" "#5" "no gate run at all flags the PR within the grace window"
assert_contains "$out" "never started" "reason says the gate never started"

# ── 6. gate none, NO run, PR younger than grace: healthy (still spinning up) ─
new_case no_run_within_grace_healthy
status_fixture sha6 ""
run_fixture sha6 '[]'
fresh="$(ago $((5*60)))" # 5 minutes old
out=$(one_pr 6 sha6 "$fresh" | run_classify)
assert_eq "" "$out" "a fresh PR with no run yet is still within the grace period"

# ── 7. gate none, only a COMPLETED run and no status posted: wedged (crash) ─
new_case completed_run_no_status_wedged
status_fixture sha7 ""
run_fixture sha7 '[{"status":"completed","createdAt":"2026-09-26T11:40:00Z"}]'
past_grace="$(ago $((15*60)))"
out=$(one_pr 7 sha7 "$past_grace" | run_classify)
assert_contains "$out" "#7" "a completed run with no posted status flags the PR"
assert_contains "$out" "no status was posted" "reason names the crashed gate"

# ── 8. run-lookup itself fails: falls back to the 3h age rule (old enough) ──
new_case lookup_fails_falls_back_wedged
status_fixture sha8 pending
export GH_FAIL_PATTERNS="run list.*sha8"
old="$(ago $((4*3600)))" # 4h old
out=$(one_pr 8 sha8 "$old" | run_classify)
assert_contains "$out" "#8" "failed run-lookup falls back to the age rule"
assert_contains "$out" "stale / never gated" "fallback reason matches the old 3h wording"
unset GH_FAIL_PATTERNS

# ── 9. run-lookup fails, PR under 3h: fallback rule reads it as healthy ────
new_case lookup_fails_under_3h_healthy
status_fixture sha9 pending
export GH_FAIL_PATTERNS="run list.*sha9"
recent="$(ago $((1*3600)))" # 1h old
out=$(one_pr 9 sha9 "$recent" | run_classify)
assert_eq "" "$out" "failed run-lookup under 3h old reads as healthy (fallback grace)"
unset GH_FAIL_PATTERNS

report
