#!/usr/bin/env bash
# Post-merge closure verification (ops#305).
#
# THE DEFECT. A Ralph PR merges with a closing keyword in its body and GitHub's
# linkage silently fails to fire. The issue stays open and `ralph-ready`, the
# loop re-claims it, the agent correctly reports "already shipped, nothing to
# do", and the cycle repeats. ops#156 did that 12+ times in ~12 hours.
#
# WHY THE PROMPT RULE IS NOT ENOUGH. ops#305 framed this as a *breakable
# reference* — `Closes **#44**` (ops#44) and the middot list
# `Closes #186 · #187 · #188 · #191 · #196` (PR #311, which lost three issues).
# Both are real. But on 2026-09-16 PR #360 carried a clean, bare `Closes #297`
# on its own line, based on the default branch, and merged — and #297 stayed
# open anyway. Correct syntax is NOT sufficient, so a pre-merge body check
# cannot be the primary defence. Verifying the transition afterwards is the only
# mechanism that catches a failure whose syntax was already right.
#
# THE SAFETY GUARD. Closing an issue just because a PR merged would be wrong —
# reconcile_issue's own step 6 exists because merged work often leaves a
# remainder. So this closes ONLY when the PR body actually contains a closing
# keyword naming that issue. We are repairing a linkage the author expressed,
# never inventing intent they did not.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

run_verify() { # <pr>
  (cd "$CASE" && bash ralph/lib.sh verify_issue_closed "$1" 2>>stderr.log)
}

pr_view() { # <n> <state> <body>  — the PR the merge just landed
  fixture "pr_view_$1.json" <<JSON
{"headRefName": "ralph/issue-126-modes", "state": "$2", "body": $3}
JSON
}

issue_open() {
  fixture issue_view_state_126.json <<'JSON'
{"state": "OPEN", "labels": [{"name": "ralph-ready"}]}
JSON
}

issue_closed() {
  fixture issue_view_state_126.json <<'JSON'
{"state": "CLOSED", "labels": []}
JSON
}

# ── 1. THE ops#297 SHAPE: a bare, well-formed keyword that still didn't fire ─
new_case bare_keyword_linkage_failed
pr_view 171 MERGED '"Adds the thing.\n\nCloses #126\n\n🤖 Generated with Claude Code"'
issue_open
run_verify 171 >/dev/null
assert_mutation "issue close 126" "repairs the failed linkage"

# ── 2. THE ops#44 SHAPE: markdown emphasis broke the keyword ────────────────
new_case bold_keyword_linkage_failed
pr_view 171 MERGED '"Adds the thing.\n\nCloses **#126**\n"'
issue_open
run_verify 171 >/dev/null
assert_mutation "issue close 126" "a bold reference is still a closing intent"

# ── 3. THE PR #311 SHAPE: a middot list GitHub parses as one keyword ────────
# This form lost THREE issues in one merge. Every number in the list counts.
new_case middot_list_linkage_failed
pr_view 171 MERGED '"Bundle.\n\nCloses #124 · #126 · #131\n"'
issue_open
run_verify 171 >/dev/null
assert_mutation "issue close 126" "every number in a middot list counts"

# ── 4. NO closing keyword → never close. This is the safety guard ───────────
# Merged work routinely leaves a remainder; reconcile_issue's step 6 exists for
# exactly that. Absent an explicit closing intent we must not invent one.
new_case no_keyword_never_closes
pr_view 171 MERGED '"Partial progress on the schema. More to follow; see #126 for the rest."'
issue_open
run_verify 171 >/dev/null
assert_no_mutation "issue close" "a bare mention is not a closing intent"

# ── 5. A DIFFERENT issue's keyword must not close this one ─────────────────
new_case other_issue_keyword_ignored
pr_view 171 MERGED '"Adds the thing.\n\nCloses #999\n"'
issue_open
run_verify 171 >/dev/null
assert_no_mutation "issue close" "only the branch's own issue is closed"

# ── 6. Already closed → no-op, and no duplicate comment ────────────────────
new_case already_closed_is_a_noop
pr_view 171 MERGED '"Closes #126"'
issue_closed
run_verify 171 >/dev/null
assert_no_mutation "issue close" "linkage worked; nothing to repair"
assert_no_mutation "issue comment" "no duplicate noise on a healthy merge"

# ── 7. An UNMERGED PR must never close anything ────────────────────────────
new_case unmerged_pr_never_closes
pr_view 171 OPEN '"Closes #126"'
issue_open
run_verify 171 >/dev/null
assert_no_mutation "issue close" "an open PR has shipped nothing"

# ── 8. A non-ralph branch is out of scope ──────────────────────────────────
new_case foreign_branch_ignored
fixture pr_view_171.json <<'JSON'
{"headRefName": "claude/some-human-branch", "state": "MERGED", "body": "Closes #126"}
JSON
issue_open
run_verify 171 >/dev/null
assert_no_mutation "issue close" "only ralph/issue-* branches are verified"

# ── 9. API blindness fails SAFE — never close on an unknown state ──────────
new_case api_failure_fails_safe
pr_view 171 MERGED '"Closes #126"'
export GH_FAIL_PATTERNS='issue view .*--json state'
run_verify 171 >/dev/null
assert_no_mutation "issue close" "unknown issue state closes nothing"

report
