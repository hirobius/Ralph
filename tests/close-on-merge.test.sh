#!/usr/bin/env bash
# ops#531: a merged Ralph PR whose body names the issue with a closing keyword
# but left it open must CLOSE the issue (not park it), and the kit's own close
# runs the optional consumer hook ralph/post-close.sh <n>.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

run_next() {
  NEXT_CODE=0
  (cd "$CASE" && bash ralph/next.sh 2>>stderr.log) || NEXT_CODE=$?
}

world() { # <pr-body-json-string>
  fixture issue_list.json <<'JSON'
[{"number": 126, "labels": [{"name": "ralph-ready"}],
  "body": "## DoD\n- [ ] snapshots exist"}]
JSON
  fixture pr_list_all.json <<JSON
[{"number": 529, "headRefName": "ralph/issue-126-aa", "state": "MERGED",
  "mergedAt": "2026-07-12T09:21:00Z", "closedAt": "2026-07-12T09:21:00Z",
  "body": $1}]
JSON
  fixture api_issue_events_126.json <<'JSON'
[{"event": "labeled", "label": {"name": "ralph-ready"},
  "created_at": "2026-07-09T06:00:00Z"}]
JSON
}

hook() { # <exit-code> — consumer hook that records its argv
  cat >"$CASE/ralph/post-close.sh" <<SH
#!/usr/bin/env bash
echo "hook \$*" >>"$CASE/hook.log"
exit $1
SH
  chmod +x "$CASE/ralph/post-close.sh"
}

hook_log() { cat "$CASE/hook.log" 2>/dev/null || true; }

# ── 1. closing keyword → closed as completed, not parked ─────────────────────
new_case keyword_closes
world '"Does it.\n\nCloses #126\n"'
run_next
assert_eq 10 "$NEXT_CODE" "queue exhausts (closed issue is not picked)"
assert_mutation "issue close 126 --reason completed" "closed as completed"
assert_mutation "#529" "comment links the PR"
assert_no_mutation "--add-label needs-adrian" "not parked"

# ── 2. other keyword forms, case-insensitive ─────────────────────────────────
new_case resolved_lowercase
world '"resolved #126"'
run_next
assert_mutation "issue close 126" "resolved (lowercase) counts"

# ── 3. no keyword → still parked ─────────────────────────────────────────────
new_case no_keyword_parks
world '"Partial progress; see #126 for the rest."'
run_next
assert_no_mutation "issue close" "bare mention does not close"
assert_mutation "--add-label needs-adrian" "parked to needs-adrian"

# ── 4. keyword for a DIFFERENT issue → parked ────────────────────────────────
new_case other_issue_parks
world '"Closes #1260"'
run_next
assert_no_mutation "issue close" "#1260 is not #126"
assert_mutation "--add-label needs-adrian" "parked"

# ── 5. hook present → called with the number ─────────────────────────────────
new_case hook_called
world '"Closes #126"'
hook 0
run_next
assert_eq "hook 126" "$(hook_log)" "post-close.sh got the issue number"

# ── 6. hook absent → fine ────────────────────────────────────────────────────
new_case hook_absent
world '"Closes #126"'
run_next
assert_mutation "issue close 126" "closes without a hook"
assert_eq 10 "$NEXT_CODE" "run is not failed"

# ── 7. hook fails → warning only ─────────────────────────────────────────────
new_case hook_fails
world '"Closes #126"'
hook 3
run_next
assert_eq 10 "$NEXT_CODE" "failing hook does not fail the run"
assert_contains "$(cat "$CASE/stderr.log")" "post-close hook failed" "warning logged"

# ── 8. non-executable hook is ignored ────────────────────────────────────────
new_case hook_not_executable
world '"Closes #126"'
hook 0
chmod -x "$CASE/ralph/post-close.sh"
run_next
assert_eq "" "$(hook_log)" "non-executable hook not run"

# ── 9. verify_issue_closed (the linkage repair) also runs the hook ───────────
new_case verify_runs_hook
fixture pr_view_171.json <<'JSON'
{"headRefName": "ralph/issue-126-modes", "state": "MERGED", "body": "Closes #126"}
JSON
fixture issue_view_state_126.json <<'JSON'
{"state": "OPEN", "labels": []}
JSON
hook 0
(cd "$CASE" && bash ralph/lib.sh verify_issue_closed 171 2>>stderr.log) >/dev/null
assert_mutation "issue close 126" "linkage repaired"
assert_eq "hook 126" "$(hook_log)" "hook runs after verify_issue_closed too"

report
