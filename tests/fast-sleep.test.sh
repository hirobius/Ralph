#!/usr/bin/env bash
# Test speed (ralph#40): retry/backoff sleeps are stubbed in tests, so a
# retried gh call costs no wall time, and the backoff schedule is still
# asserted from the sleep log instead of by waiting it out.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

new_case gh_retry_backoff_is_recorded_not_slept
export GH_FAIL_PATTERNS="api repos/hirobius/test/issues/7"
start=$(date +%s)
(
  # shellcheck source=/dev/null
  . "$CASE/ralph/lib.sh"
  gh_retry api repos/hirobius/test/issues/7 >/dev/null 2>&1
)
rc=$?
elapsed=$(($(date +%s) - start))
assert_eq 1 "$rc" "gh_retry gives up after 3 failed attempts"
assert_eq "2 4 8" "$(sleep_log)" "the backoff schedule is 2s, 4s, 8s"
assert_eq 1 "$([ "$elapsed" -le 2 ] && echo 1 || echo 0)" "no real sleeping (took ${elapsed}s)"

new_case sleep_log_starts_empty
assert_eq "" "$(sleep_log)" "each case gets a fresh sleep log"

report
