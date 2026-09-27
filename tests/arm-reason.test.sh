#!/usr/bin/env bash
# ralph_arm_reason tests (ralph#26).
#
# THE MECHANISM. With RALPH_DEFAULT_AUTO_MERGE set in a caller's
# ralph/config.env, a green ralph-gate + AI approve arms auto-merge with NO
# label at all — ralph_arm_reason is the pure decision fn behind that,
# shared by the workflow's arming step. It takes <pr_ok> <issue_ok>
# ("true"/"false", the workflow's existing label checks) and the diff's
# changed paths on stdin, and decides whether to arm and why.
#
# THE BOUNDARY APPLIES TO ALL THREE REASONS. ralph#25's supervised-path
# check must gate ralph-approved and issue ralph-auto exactly as it gates
# the new default-posture reason — an approve label on a revenue-path PR
# must not merge unattended either.
#
# FAIL CLOSED. A boundary command that can't be read must block arming
# under every flag/label combination — never silently arm because the
# manifest broke.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

run() { # <pr_ok> <issue_ok> <changed-paths-newline-separated>
  RUN_CODE=0
  RUN_OUT=$(cd "$CASE" && printf '%s' "$3" |
    RALPH_SUPERVISED_CMD="${RALPH_SUPERVISED_CMD:-}" \
    RALPH_DEFAULT_AUTO_MERGE="${RALPH_DEFAULT_AUTO_MERGE:-false}" \
    bash ralph/lib.sh ralph_arm_reason "$1" "$2" 2>>stderr.log) || RUN_CODE=$?
}

manifest_cmd_ok() { # <manifest-lines>
  local f
  f="$CASE/manifest.sh"
  {
    echo '#!/usr/bin/env bash'
    printf 'cat <<'"'"'EOF'"'"'\n%s\nEOF\n' "$1"
  } >"$f"
  chmod +x "$f"
  RALPH_SUPERVISED_CMD="bash $f"
}

manifest_cmd_fails() {
  local f
  f="$CASE/manifest.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$f"
  chmod +x "$f"
  RALPH_SUPERVISED_CMD="bash $f"
}

# ── 1. approve label wins, prints ralph-approved ─────────────────────────
new_case pr_ok_arms
unset RALPH_SUPERVISED_CMD RALPH_DEFAULT_AUTO_MERGE
run true false $'src/App.tsx'
assert_eq 0 "$RUN_CODE" "pr_ok=true arms"
assert_eq "ralph-approved" "$RUN_OUT" "reason string is ralph-approved"

# ── 2. issue pre-tagged ralph-auto arms ──────────────────────────────────
new_case issue_ok_arms
unset RALPH_SUPERVISED_CMD RALPH_DEFAULT_AUTO_MERGE
run false true $'src/App.tsx'
assert_eq 0 "$RUN_CODE" "issue_ok=true arms"
assert_eq "issue ralph-auto" "$RUN_OUT" "reason string is issue ralph-auto"

# ── 3. default posture arms when the flag is on, nothing else set ───────
new_case default_posture_arms
unset RALPH_SUPERVISED_CMD
RALPH_DEFAULT_AUTO_MERGE=true
run false false $'src/App.tsx'
assert_eq 0 "$RUN_CODE" "RALPH_DEFAULT_AUTO_MERGE=true arms with no label at all"
assert_eq "default posture" "$RUN_OUT" "reason string is default posture"

# ── 4. flag unset + no label → no arm ────────────────────────────────────
new_case flag_unset_no_label_no_arm
unset RALPH_SUPERVISED_CMD RALPH_DEFAULT_AUTO_MERGE
run false false $'src/App.tsx'
assert_eq 1 "$RUN_CODE" "no label, no flag — does not arm"
assert_eq "" "$RUN_OUT" "prints nothing"

# ── 5. flag off explicitly + no label → no arm ───────────────────────────
new_case flag_false_no_label_no_arm
unset RALPH_SUPERVISED_CMD
RALPH_DEFAULT_AUTO_MERGE=false
run false false $'src/App.tsx'
assert_eq 1 "$RUN_CODE" "RALPH_DEFAULT_AUTO_MERGE=false, no label — does not arm"
assert_eq "" "$RUN_OUT" "prints nothing"

# ── 6. flag on + supervised diff → no arm (boundary beats default posture)
new_case flag_on_supervised_diff_no_arm
manifest_cmd_ok $'lib/leads/'
RALPH_DEFAULT_AUTO_MERGE=true
run false false $'lib/leads/foo.mjs'
assert_eq 1 "$RUN_CODE" "flag on but diff is supervised — does not arm"
assert_eq "" "$RUN_OUT" "prints nothing"

# ── 7. supervised diff blocks ralph-approved too ─────────────────────────
new_case supervised_diff_blocks_pr_ok
manifest_cmd_ok $'lib/leads/'
unset RALPH_DEFAULT_AUTO_MERGE
run true false $'lib/leads/foo.mjs'
assert_eq 1 "$RUN_CODE" "approve label present but diff is supervised — does not arm"
assert_eq "" "$RUN_OUT" "prints nothing"

# ── 8. supervised diff blocks issue ralph-auto too ───────────────────────
new_case supervised_diff_blocks_issue_ok
manifest_cmd_ok $'lib/leads/'
unset RALPH_DEFAULT_AUTO_MERGE
run false true $'lib/leads/foo.mjs'
assert_eq 1 "$RUN_CODE" "issue pre-tagged but diff is supervised — does not arm"
assert_eq "" "$RUN_OUT" "prints nothing"

# ── 9. boundary cmd fails (non-zero) → no arm under EVERY flag value ─────
new_case boundary_fails_default_true_no_arm
manifest_cmd_fails
RALPH_DEFAULT_AUTO_MERGE=true
run true true $'src/App.tsx'
assert_eq 1 "$RUN_CODE" "boundary command fails closed — no arm even with pr_ok+issue_ok+flag all true"
assert_eq "" "$RUN_OUT" "prints nothing"

new_case boundary_fails_default_false_no_arm
manifest_cmd_fails
RALPH_DEFAULT_AUTO_MERGE=false
run false false $'src/App.tsx'
assert_eq 1 "$RUN_CODE" "boundary command fails closed with flag false too — no arm"
assert_eq "" "$RUN_OUT" "prints nothing"

new_case boundary_fails_default_unset_no_arm
manifest_cmd_fails
unset RALPH_DEFAULT_AUTO_MERGE
run true false $'src/App.tsx'
assert_eq 1 "$RUN_CODE" "boundary command fails closed with flag unset too — no arm"
assert_eq "" "$RUN_OUT" "prints nothing"

# ── 10. priority: pr_ok beats issue_ok when both true ────────────────────
new_case priority_pr_ok_over_issue_ok
unset RALPH_SUPERVISED_CMD RALPH_DEFAULT_AUTO_MERGE
run true true $'src/App.tsx'
assert_eq 0 "$RUN_CODE" "both labels present — arms"
assert_eq "ralph-approved" "$RUN_OUT" "ralph-approved takes priority over issue ralph-auto"

# ── 11. priority: an explicit label wins over default posture ───────────
new_case priority_issue_ok_over_default
unset RALPH_SUPERVISED_CMD
RALPH_DEFAULT_AUTO_MERGE=true
run false true $'src/App.tsx'
assert_eq 0 "$RUN_CODE" "issue tag + flag both true — arms"
assert_eq "issue ralph-auto" "$RUN_OUT" "issue ralph-auto takes priority over default posture"

report
