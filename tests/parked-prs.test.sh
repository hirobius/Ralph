#!/usr/bin/env bash
# Decision-table tests for ops#476 — a Ralph PR labelled needs-adrian is
# PARKED on a human and no longer holds single-flight (run.sh exit 13); any
# other open Ralph PR is ACTIVE and still does. status.sh lists the two apart,
# and next.sh never re-picks the issue that owns an open (parked) PR.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# pr <n> [labels-csv] -> one open-PR JSON object (gh pr list shape)
pr() {
  local labels="" l
  IFS=, read -ra arr <<<"${2:-}"
  for l in "${arr[@]}"; do [ -n "$l" ] && labels="$labels{\"name\":\"$l\"},"; done
  printf '{"number":%s,"headRefName":"ralph/issue-%s-x","headRefOid":"sha%s","updatedAt":"%s","labels":[%s]}' \
    "$1" "$1" "$1" "$NOW" "${labels%,}"
}

open_fixture() { # <pr-object>...
  local IFS=,
  fixture pr_list_open.json <<<"[$*]"
}

# Every PR's gate is green so classify_wedged calls an active PR healthy.
green() { # <n>...
  local n
  for n in "$@"; do
    fixture "commit_status_sha$n.json" <<'JSON'
{"statuses":[{"context":"ralph-gate","state":"success","created_at":"2026-09-26T11:00:00Z"}]}
JSON
  done
}

libfn() { (cd "$CASE" && bash ralph/lib.sh "$@"); }
count() { jq length <<<"$1"; }

run_sh() { # exit code of run.sh lands in RUN_CODE
  RUN_CODE=0
  (cd "$CASE" && GITHUB_ACTIONS=1 RALPH_DRY_RUN=1 bash ralph/run.sh >run.out 2>&1) || RUN_CODE=$?
}

status_out() { (cd "$CASE" && bash ralph/status.sh 2>&1); }

check() { # <case> <active-count> <parked-count> <run-exit-13?yes|no> <prs...>
  local name=$1 a=$2 p=$3 blocks=$4
  shift 4
  new_case "$name"
  open_fixture "$@"
  green 1 2 3
  assert_eq "$a" "$(count "$(libfn open_ralph_prs)")" "active PRs"
  assert_eq "$p" "$(count "$(libfn parked_ralph_prs)")" "parked PRs"
  run_sh
  if [ "$blocks" = yes ]; then
    assert_eq 13 "$RUN_CODE" "single-flight holds (exit 13)"
  else
    [ "$RUN_CODE" -ne 13 ] && ! grep -q "gh pr list failed" "$CASE/run.out" && _ok "single-flight does not hold (exit $RUN_CODE)" ||
      _fail "single-flight does not hold" "run.sh exited 13: $(cat "$CASE/run.out")"
  fi
}

# ── decision table ──────────────────────────────────────────────────────────
check zero_prs 0 0 no
check one_active 1 0 yes "$(pr 1)"
check one_parked 0 1 no "$(pr 2 needs-adrian)"
check one_active_one_parked 1 1 yes "$(pr 1)" "$(pr 2 needs-adrian)"
check active_with_other_labels 1 0 yes "$(pr 1 ralph-approved,p1)"
check two_parked_dont_block 0 2 no "$(pr 2 needs-adrian)" "$(pr 3 p1,needs-adrian)"

# claim refs and non-ralph branches are never PRs
new_case claim_and_foreign_branches_ignored
fixture pr_list_open.json <<JSON
[{"number":7,"headRefName":"ralph/claim-9","headRefOid":"s7","updatedAt":"$NOW","labels":[]},
 {"number":8,"headRefName":"feature/x","headRefOid":"s8","updatedAt":"$NOW","labels":[]}]
JSON
assert_eq 0 "$(count "$(libfn open_ralph_prs)")" "no active"
assert_eq 0 "$(count "$(libfn parked_ralph_prs)")" "no parked"

# ── status.sh lists parked separately from in-flight ────────────────────────
new_case status_separates_parked
open_fixture "$(pr 1)" "$(pr 2 needs-adrian)"
green 1 2
fixture issue_list.json <<<'[]'
out=$(status_out)
inflight=$(sed -n '/in-flight ralph PRs/,/parked ralph PRs/p' <<<"$out")
parked=$(sed -n '/parked ralph PRs/,/active claims/p' <<<"$out")
assert_contains "$inflight" "#1 " "#1 listed in-flight"
assert_eq "" "$(grep -F '#2 ' <<<"$inflight")" "#2 not listed in-flight"
assert_contains "$parked" "#2 " "#2 listed parked"
assert_eq "" "$(grep -F '#1 ' <<<"$parked")" "#1 not listed parked"

# ── next.sh never re-picks the issue that owns a parked/open PR ──────────────
new_case parked_pr_issue_not_repicked
fixture issue_list.json <<'JSON'
[{"number": 2, "labels": [{"name": "ralph-ready"}, {"name": "p0"}],
  "body": "## DoD\n- [ ] done"}]
JSON
fixture pr_list_all.json <<'JSON'
[{"headRefName": "ralph/issue-2-x", "state": "OPEN", "mergedAt": null, "closedAt": null}]
JSON
sel=$(cd "$CASE" && bash ralph/next.sh 2>>"$CASE/stderr.log")
code=$?
assert_eq 10 "$code" "queue reads exhausted"
assert_eq "" "$sel" "ralph-ready issue owning a parked PR is not selected"
assert_no_mutation "--add-label" "and is not re-parked or relabelled"

# ...while a different ready issue is still picked
new_case frontier_continues_past_parked
fixture issue_list.json <<'JSON'
[{"number": 2, "labels": [{"name": "ralph-ready"}, {"name": "p0"}],
  "body": "## DoD\n- [ ] done"},
 {"number": 3, "labels": [{"name": "ralph-ready"}, {"name": "p1"}],
  "body": "## DoD\n- [ ] done"}]
JSON
fixture pr_list_all.json <<'JSON'
[{"headRefName": "ralph/issue-2-x", "state": "OPEN", "mergedAt": null, "closedAt": null}]
JSON
fixture api_issue_events_3.json <<'JSON'
[{"event": "labeled", "label": {"name": "ralph-ready"}, "created_at": "2026-07-09T06:00:00Z"}]
JSON
fixture issue_view_comments_3.json <<'JSON'
{"comments": []}
JSON
sel=$(cd "$CASE" && bash ralph/next.sh 2>>"$CASE/stderr.log")
assert_eq 3 "$sel" "the loop keeps working the frontier"

report
