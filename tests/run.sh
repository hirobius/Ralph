#!/usr/bin/env bash
# Run every kit test (or the suites named as arguments) in parallel; print
# each suite's output in a fixed order and exit non-zero if any suite fails.
# RALPH_TEST_JOBS caps concurrency (default: CPU count, 4 if unknown).
set -uo pipefail
cd "$(dirname "$0")" || exit 1

if [ "$#" -gt 0 ]; then
  suites=("$@")
else
  suites=(./*.test.sh)
fi
jobs=${RALPH_TEST_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
[ "$jobs" -ge 1 ] 2>/dev/null || jobs=4

out=$(mktemp -d "${TMPDIR:-/tmp}/ralph-run-XXXXXX")
trap 'rm -rf "$out"' EXIT

i=0
for t in "${suites[@]}"; do
  while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do wait -n 2>/dev/null || wait; done # bash<4.3 (macOS): wait for the batch
  (bash "$t" >"$out/$i.log" 2>&1; echo $? >"$out/$i.rc") &
  i=$((i + 1))
done
wait

rc=0
failed=""
i=0
for t in "${suites[@]}"; do
  echo "== $t"
  cat "$out/$i.log"
  if [ "$(cat "$out/$i.rc" 2>/dev/null || echo 1)" != 0 ]; then
    rc=1
    failed="$failed $t"
  fi
  i=$((i + 1))
done
[ -z "$failed" ] || echo "FAILED:$failed" >&2
exit "$rc"
