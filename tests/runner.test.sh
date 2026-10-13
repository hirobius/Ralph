#!/usr/bin/env bash
# tests/run.sh (ralph#40): suites run in parallel, but their output prints in
# a fixed order (the order given), and the run fails when any suite fails.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

new_case ordered_output_and_failure_exit
d="$CASE/suites"
mkdir -p "$d"
# a.test.sh finishes last but must print first.
printf '#!/usr/bin/env bash\n/bin/sleep 0.3; echo "alpha done"\n' >"$d/a.test.sh"
printf '#!/usr/bin/env bash\necho "beta failed" >&2; exit 1\n' >"$d/b.test.sh"
printf '#!/usr/bin/env bash\necho "gamma done"\n' >"$d/c.test.sh"
out=$(bash "$TESTS_DIR/run.sh" "$d/a.test.sh" "$d/b.test.sh" "$d/c.test.sh" 2>&1) && rc=0 || rc=$?
assert_eq 1 "$rc" "one failing suite fails the run"
order=$(grep -oE 'alpha done|beta failed|gamma done' <<<"$out" | tr '\n' ' ')
assert_eq "alpha done beta failed gamma done " "$order" "output keeps the given order"
assert_contains "$out" "FAILED: $d/b.test.sh" "the failing suite is named at the end"

new_case all_green_exit_zero
d="$CASE/suites"
mkdir -p "$d"
printf '#!/usr/bin/env bash\necho ok\n' >"$d/a.test.sh"
out=$(RALPH_TEST_JOBS=1 bash "$TESTS_DIR/run.sh" "$d/a.test.sh" 2>&1) && rc=0 || rc=$?
assert_eq 0 "$rc" "all suites green exits 0 (RALPH_TEST_JOBS=1 works)"

report
