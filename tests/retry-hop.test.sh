#!/usr/bin/env bash
# retry_hop_issue tests (ops#481).
#
# THE GAP. A failed attempt with budget left released its claim and stopped.
# Nothing re-ran it until the watchdog cron or the 6h schedule, both of which
# GitHub throttles: ops#535 sat idle for hours after attempt 1/2 failed.
#
# THE FIX. reconcile's outcome decides a retry hop. Only `failed:` with a
# readable "(attempt N/M)" and N<M retries. Parked, shipped, an unreadable
# budget, and the last attempt never do — the attempt cap bounds the loop.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

hop() { # <outcome> <issue>
  (cd "$CASE" && bash ralph/lib.sh retry_hop_issue "$1" "$2" 2>>stderr.log)
}

new_case "attempt 1/2 failed"
assert_eq "535" "$(hop 'failed:iteration ended without a pushed branch (attempt 1/2)' 535)" "retries with budget left"

new_case "last attempt failed"
assert_eq "" "$(hop 'failed:boom (attempt 2/2)' 535)" "no retry on the last attempt"

new_case "budget unreadable"
assert_eq "" "$(hop 'failed:boom (attempt budget unverifiable — API failure; selection re-checks fail-closed)' 535)" "no retry when budget unknown"

new_case "parked"
assert_eq "" "$(hop 'parked:gave up after 2 failed attempt(s)' 535)" "no retry when parked"

new_case "shipped"
assert_eq "" "$(hop 'pr:612' 535)" "no retry when a PR shipped"

new_case "budget over cap"
assert_eq "" "$(hop 'failed:boom (attempt 3/2)' 535)" "no retry past the cap"

report
