#!/usr/bin/env bash
# ops#296: a missing DoD checklist drafts one as a comment instead of a bare
# park. Covers: the draft comment is posted (marker + fallback content), the
# issue body is never touched, needs-adrian still applies (no attempt burned,
# queue still exhausts), the park reason reads as a draft-awaiting-review
# rather than a rejection, and RALPH_DOD_DRAFT_CMD (when configured) wins over
# the heuristic fallback.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

no_dod_issue_7() {
  fixture issue_list.json <<'JSON'
[{"number": 7, "labels": [{"name": "ralph-ready"}, {"name": "p1"}],
  "body": "Some prose with no checklist at all — just a discussion."}]
JSON
  fixture pr_list_all.json <<'JSON'
[]
JSON
}

run() { NEXT_CODE=0; (cd "$CASE" && bash ralph/next.sh 2>>stderr.log) || NEXT_CODE=$?; }

# ── 1. Missing checklist drafts a comment, never edits the body ──────────────
new_case draft_comment_not_body_edit
no_dod_issue_7
run
assert_eq 10 "$NEXT_CODE" "queue exhausts (single candidate, drafted+parked)"
assert_mutation "ralph-dod-draft:" "draft comment posted with its marker"
assert_mutation "issue comment 7" "posted on the right issue"
assert_mutation "--add-label needs-adrian" "still routes to needs-adrian"
assert_mutation "--remove-label ralph-ready" "pulled from the ready queue"
assert_no_mutation "issue edit 7 --body" "the issue body itself is never edited"

# ── 2. Park reason reads as a draft awaiting review, not a rejection ─────────
new_case draft_reason_wording
no_dod_issue_7
run
assert_mutation "a draft awaiting your thumbs-up, not a rejection" "wording distinguishes draft from rejection"

# ── 3. Heuristic fallback fires when no RALPH_DOD_DRAFT_CMD is configured ────
new_case heuristic_fallback_used
fixture issue_list.json <<'JSON'
[{"number": 9, "labels": [{"name": "ralph-ready"}, {"name": "p1"}],
  "body": "prose\n- do the thing\n- and the other thing"}]
JSON
fixture pr_list_all.json <<'JSON'
[]
JSON
run
assert_mutation "TODO (drafted, unreviewed): confirm the concrete outcome" "heuristic drafter ran"
assert_mutation "[ ] do the thing" "heuristic lifts existing bullets into checklist items"

# ── 4. RALPH_DOD_DRAFT_CMD (the haiku-hook) wins over the heuristic ──────────
new_case configured_drafter_wins
fixture issue_list.json <<'JSON'
[{"number": 11, "labels": [{"name": "ralph-ready"}, {"name": "p1"}],
  "body": "no checklist here"}]
JSON
fixture pr_list_all.json <<'JSON'
[]
JSON
export RALPH_DOD_DRAFT_CMD="cat <<'EOF'
- [ ] a real drafted item from the configured drafter
EOF"
run
unset RALPH_DOD_DRAFT_CMD
assert_mutation "a real drafted item from the configured drafter" "configured drafter's output is used"
assert_no_mutation "TODO (drafted, unreviewed)" "heuristic did not also run"

# ── 5. A blank RALPH_DOD_DRAFT_CMD output falls back to the heuristic ───────
new_case configured_drafter_blank_falls_back
fixture issue_list.json <<'JSON'
[{"number": 13, "labels": [{"name": "ralph-ready"}, {"name": "p1"}],
  "body": "no checklist here either"}]
JSON
fixture pr_list_all.json <<'JSON'
[]
JSON
export RALPH_DOD_DRAFT_CMD="true"
run
unset RALPH_DOD_DRAFT_CMD
assert_mutation "TODO (drafted, unreviewed): confirm the concrete outcome" "blank output falls back to heuristic"

# ── 6. Unit: draft_dod_checklist always carries the marker as the first line ─
new_case draft_fn_marker_first_line
out=$(cd "$CASE" && . ralph/lib.sh && draft_dod_checklist "anything")
assert_eq "ralph-dod-draft:" "$(head -n1 <<<"$out")" "marker is the first line"

report
