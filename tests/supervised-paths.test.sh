#!/usr/bin/env bash
# ralph_diff_is_supervised tests (ralph#25).
#
# THE BOUNDARY. Today `ralph-auto` on the linked issue (or `ralph-approved` on
# the PR) arms auto-merge with NO path inspection at all — a `ralph-auto`
# issue whose diff touches a revenue path merges unattended. This is the
# consumer side of ops#400's supervised-path manifest
# (`scripts/ralph-supervised-paths.mjs`): RALPH_SUPERVISED_CMD is a caller-
# configured command that prints the manifest, one entry per line — a
# trailing `/` is a directory-prefix match, anything else is an exact-file
# match — and ralph_diff_is_supervised cross-references the diff's changed
# paths (stdin, one per line) against it.
#
# FAIL CLOSED. A configured command that exits non-zero or prints nothing
# must never read as "nothing is supervised" — that would silently disarm
# the boundary the moment the manifest script breaks. It reports the WHOLE
# diff supervised instead.
#
# UNCONFIGURED = TODAY'S BEHAVIOUR. hds and site-engine have no boundary
# command yet (ralph#25's own DoD). RALPH_SUPERVISED_CMD unset must reach the
# identical "not supervised" path they get today, not a new default-block.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

run() { # <changed-paths-newline-separated>
  RUN_CODE=0
  RUN_OUT=$(cd "$CASE" && printf '%s' "$1" | RALPH_SUPERVISED_CMD="${RALPH_SUPERVISED_CMD:-}" bash ralph/lib.sh ralph_diff_is_supervised 2>>stderr.log) || RUN_CODE=$?
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

manifest_cmd_empty() {
  local f
  f="$CASE/manifest.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$f"
  chmod +x "$f"
  RALPH_SUPERVISED_CMD="bash $f"
}

# ── 1. prefix match ──────────────────────────────────────────────────────
new_case prefix_match
manifest_cmd_ok $'lib/leads/\napi/lead-action.ts'
run $'src/App.tsx\nlib/leads/foo.mjs'
assert_eq 0 "$RUN_CODE" "diff touching lib/leads/foo.mjs under a lib/leads/ prefix is SUPERVISED"
assert_contains "$RUN_OUT" "lib/leads/foo.mjs" "names the matched path"

# ── 2. exact-file match ──────────────────────────────────────────────────
new_case exact_file_match
manifest_cmd_ok $'lib/leads/\napi/lead-action.ts'
run $'api/lead-action.ts'
assert_eq 0 "$RUN_CODE" "diff touching the exact supervised file is SUPERVISED"
assert_contains "$RUN_OUT" "api/lead-action.ts" "names the matched path"

# ── 3. clean diff ────────────────────────────────────────────────────────
new_case clean_diff
manifest_cmd_ok $'lib/leads/\napi/lead-action.ts'
run $'src/App.tsx\ndocs/README.md'
assert_eq 1 "$RUN_CODE" "a diff that touches none of the manifest is NOT supervised"

# ── 4. no command configured → not supervised (today's behaviour) ───────
new_case no_command_configured
unset RALPH_SUPERVISED_CMD
run $'lib/leads/foo.mjs'
assert_eq 1 "$RUN_CODE" "RALPH_SUPERVISED_CMD unset reaches the identical not-supervised path as today"

# ── 5. command exits non-zero → FAILS CLOSED ─────────────────────────────
new_case command_fails
manifest_cmd_fails
run $'src/App.tsx'
assert_eq 0 "$RUN_CODE" "a failing manifest command fails CLOSED — the diff is reported supervised"

# ── 6. command prints nothing → FAILS CLOSED ─────────────────────────────
new_case command_prints_nothing
manifest_cmd_empty
run $'src/App.tsx'
assert_eq 0 "$RUN_CODE" "an empty manifest fails CLOSED — the diff is reported supervised"

report
