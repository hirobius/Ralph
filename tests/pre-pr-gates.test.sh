#!/usr/bin/env bash
# Pre-PR gates (ops#504): tests-with-code hook, /pr body headings, red-first.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

gate() { # <fn> [args...] — run a lib helper inside the case sandbox
  (cd "$CASE" && bash ralph/lib.sh "$@" 2>>stderr.log)
}

wt_count() { # number of extra test-run worktrees created
  if [ -f "$GH_FIX_DIR/wt_adds.log" ]; then wc -l <"$GH_FIX_DIR/wt_adds.log" | tr -d ' '; else echo 0; fi
}

# ── 1. tests-with-code: consumer hook decides ───────────────────────────────
new_case tests_hook_absent_skips
gate check_tests_with_code origin/main HEAD >/dev/null
assert_eq 0 "$?" "no check-tests.sh -> gate skipped, not failed"

new_case tests_hook_passes
printf '#!/usr/bin/env bash\nexit 0\n' >"$CASE/ralph/check-tests.sh"
chmod +x "$CASE/ralph/check-tests.sh"
gate check_tests_with_code origin/main HEAD >/dev/null
assert_eq 0 "$?" "hook exit 0 -> ok"

new_case tests_hook_not_executable_skips
printf '#!/usr/bin/env bash\nexit 1\n' >"$CASE/ralph/check-tests.sh"
gate check_tests_with_code origin/main HEAD >/dev/null
assert_eq 0 "$?" "non-executable hook is treated as absent"

new_case tests_hook_fails_blocks_pr
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\necho "src changed, no tests: $1 $2"\nexit 1\n' >"$CASE/ralph/check-tests.sh"
chmod +x "$CASE/ralph/check-tests.sh"
OUT=$(gate pre_pr_gates 7 origin/ralph/issue-7-x)
assert_eq 1 "$?" "failing hook fails pre_pr_gates"
assert_contains "$OUT" "src changed, no tests: origin/main origin/ralph/issue-7-x" "reason carries hook output and the refs"

# ── 2. PR body headings ─────────────────────────────────────────────────────
new_case body_with_headings_kept
BODY=$'Closes #7\n\n## Summary\nx\n\n## Evidence\ny\n\n## Merge Danger\nz'
OUT=$(gate pr_body_or_recovery "$BODY" 7 "feat: a" "tail" "foot")
assert_eq "$BODY" "$OUT" "valid body is passed through untouched"

new_case body_missing_heading_falls_back
OUT=$(gate pr_body_or_recovery $'Closes #7\n\n## Summary\nonly this' 7 "feat: a" "tail" "foot")
assert_contains "$OUT" "## Evidence" "fallback has Evidence"
assert_contains "$OUT" "## Merge Danger" "fallback has Merge Danger"
assert_contains "$OUT" "- feat: a" "fallback lists commits"

pr_world() { # <pr body json string>
  fixture pr_list_all.json <<'JSON'
[{"number": 55, "headRefName": "ralph/issue-7-x", "state": "OPEN", "createdAt": "2099-01-01T00:00:00Z"}]
JSON
  fixture api_issue_comments_7.json <<'JSON'
[{"body": "ralph-claim run1", "created_at": "2026-10-01T00:00:00Z"}]
JSON
  fixture pr_view_55.json <<JSON
{"body": $1, "headRefName": "ralph/issue-7-x"}
JSON
}

new_case reconcile_fixes_model_pr_body
pr_world '"Closes #7\n\njust a blurb"'
(cd "$CASE" && bash -c '. ralph/lib.sh; reconcile_issue 7 run1 "claude exit 0"') >/dev/null 2>&1
assert_mutation "pr edit 55 --body" "model PR without headings gets the recovery body"

new_case reconcile_leaves_good_model_pr_body
pr_world '"Closes #7\n\n## Summary\na\n\n## Evidence\nb\n\n## Merge Danger\nc"'
(cd "$CASE" && bash -c '. ralph/lib.sh; reconcile_issue 7 run1 "claude exit 0"') >/dev/null 2>&1
assert_no_mutation "pr edit" "model PR with headings is not touched"

new_case reconcile_recovery_blocked_by_tests_gate
fixture api_issue_comments_126.json <<'JSON'
[{"body": "ralph-claim run-1", "created_at": "2026-07-12T10:00:00Z"}]
JSON
fixture pr_list_all.json <<'JSON'
[]
JSON
fixture issue_view_state_126.json <<'JSON'
{"state": "OPEN", "labels": [{"name": "ralph-ready"}]}
JSON
printf 'deadbeef\trefs/heads/ralph/issue-126-fresh\n' >"$GH_FIX_DIR/git_ls_heads.txt"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\necho "no tests"\nexit 1\n' >"$CASE/ralph/check-tests.sh"
chmod +x "$CASE/ralph/check-tests.sh"
OUT=$(cd "$CASE" && bash ralph/lib.sh reconcile_issue 126 run-1 "claude exit 0" 2>>stderr.log)
assert_no_mutation "pr create" "failed tests gate -> no PR opened"
assert_contains "$OUT" "tests-with-code check failed" "run fails with the gate's reason"

# ── 3. red-first ────────────────────────────────────────────────────────────
tdd_world() { # <exit code the first test commit's runner returns>
  printf 'src/a.ts\ntests/a.test.ts\n' | fixture git_diff_names.txt
  printf 'aaa111\nbbb222\n' | fixture git_commits.txt
  printf 'tests/a.test.ts\n' | fixture git_files_aaa111.txt
  printf 'src/a.ts\n' | fixture git_files_bbb222.txt
  printf '#!/usr/bin/env bash\nexit %s\n' "$1" | fixture wt_runner_aaa111.sh
}

new_case tdd_red_first_ok
tdd_world 1
gate tdd_check 7 origin/main HEAD >/dev/null 2>&1
assert_eq 0 "$?" "red first test commit -> ok"
assert_no_mutation "ralph-tdd:" "no comment when red"
assert_eq 1 "$(wt_count)" "exactly one extra test run"

new_case tdd_green_first_warns_before_deadline
tdd_world 0
RALPH_TDD_ENFORCE_AFTER=2999-01-01 gate tdd_check 7 origin/main HEAD >/dev/null
assert_eq 0 "$?" "before the enforce date a mismatch only warns"
assert_mutation "ralph-tdd:" "mismatch posts a ralph-tdd: comment"

new_case tdd_green_first_fails_after_deadline
tdd_world 0
OUT=$(RALPH_TDD_ENFORCE_AFTER=2000-01-01 gate tdd_check 7 origin/main HEAD)
assert_eq 1 "$?" "after the enforce date a mismatch fails"
assert_contains "$OUT" "red-first violated" "failure names the reason"
assert_mutation "ralph-tdd:" "comment posted on failure too"

new_case tdd_default_enforce_date
VAL=$(cd "$CASE" && bash -c '. ralph/lib.sh; echo "$RALPH_TDD_ENFORCE_AFTER"')
assert_eq 2026-10-21 "$VAL" "default enforce date is 2026-10-21"

new_case tdd_no_test_commit_is_mismatch
printf 'src/a.ts\n' | fixture git_diff_names.txt
printf 'bbb222\n' | fixture git_commits.txt
printf 'src/a.ts\n' | fixture git_files_bbb222.txt
RALPH_TDD_ENFORCE_AFTER=2000-01-01 gate tdd_check 7 origin/main HEAD >/dev/null
assert_eq 1 "$?" "no test-touching commit -> mismatch"
assert_mutation "ralph-tdd:" "comment posted"
assert_eq 0 "$(wt_count)" "no test run needed when there is no test commit"

new_case tdd_docs_only_skips
printf 'README.md\ndocs/x/y.txt\n' | fixture git_diff_names.txt
gate tdd_check 7 origin/main HEAD >/dev/null 2>&1
assert_eq 0 "$?" "docs-only diff skips"
assert_no_mutation "ralph-tdd:" "no comment on docs-only"
assert_eq 0 "$(wt_count)" "no test run on docs-only"

new_case tdd_prefers_narrow_runner
tdd_world 0
RALPH_TDD_ENFORCE_AFTER=2000-01-01 gate tdd_check 7 origin/main HEAD >/dev/null
assert_eq 1 "$?" "ralph/test.sh result (green) decides the red check"

report
