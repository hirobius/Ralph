#!/usr/bin/env bash
# tests/reconcile.test.sh — regression tests for reconcile_issue(), the loop's
# single most safety-critical decision: given "the model iteration finished,
# what actually happened?", it must never conflate a DELIBERATE blocked-stop
# (the model followed prompt.md §1 and stopped on a human blocker) with a
# GENUINE failure (crash/timeout/push-fail). Conflating them burns an attempt,
# reddens the run, and halts the whole chain — the site-engine#86 fleet stall.
#
# No network: gh + git are stubbed on PATH and parametrised per case via
# FIX_STATE (issue view state,labels), FIX_COMMENTS (issue view comments), and
# FIX_PRS (pr list --state all). Run: bash tests/reconcile.test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/ralph"
cp "$ROOT/kit/lib.sh" "$TMP/ralph/lib.sh"

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  "pr list --state all"*) echo "${FIX_PRS:-[]}"; exit 0 ;;
esac
[[ "$args" == "issue view"*"state,labels"* ]] && { echo "$FIX_STATE"; exit 0; }
[[ "$args" == "issue view"*comments* ]]       && { echo "$FIX_COMMENTS"; exit 0; }
[[ "$args" == *"/events"* ]] && { echo '[{"event":"labeled","label":{"name":"ralph-ready"},"created_at":"2026-07-11T00:00:00Z"}]'; exit 0; }
exit 0   # label create/edit/comment, api delete-ref → succeed quietly
EOF
cat >"$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ls-remote) exit 0 ;;                                  # no ralph/issue-* branch
  remote)    echo "https://github.com/hirobius/ralph" ;;
  rev-parse) echo deadbeef ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/git"

recon() { # recon <FIX_STATE> <FIX_COMMENTS> [FIX_PRS]
  FIX_STATE=$1 FIX_COMMENTS=$2 FIX_PRS=${3:-[]} \
  PATH="$TMP/bin:$PATH" GITHUB_REPOSITORY=hirobius/ralph \
    bash "$TMP/ralph/lib.sh" reconcile_issue 42 test-run "claude step outcome: success" 2>/dev/null
}

pass=0 fail=0
expect() { # expect <name> <want-prefix> <got>
  if [[ "$3" == "$2"* ]]; then pass=$((pass+1)); printf 'ok   %s\n' "$1"
  else fail=$((fail+1)); printf 'FAIL %s\n       want prefix: %s\n       got:         %s\n' "$1" "$2" "$3"; fi
}

READY='{"name":"ralph-ready"}'
# A — #86 exact: model added needs-adrian → hand-off, no attempt burned
expect "deliberate stop via needs-adrian label → parked, no attempt" "parked:" \
  "$(recon '{"state":"OPEN","labels":[{"name":"ralph-ready"},{"name":"needs-adrian"}]}' '{"comments":[]}')"
# B — the gap #86 nearly hit: ralph-blocked comment, NO label change → route to needs-adrian, no attempt
expect "deliberate stop via ralph-blocked sentinel → parked, no attempt" "parked:" \
  "$(recon "{\"state\":\"OPEN\",\"labels\":[$READY]}" '{"comments":[{"body":"ralph-blocked: needs a human call","createdAt":"2026-07-12T07:56:54Z"}]}')"
# C — genuine failure: no branch, no signal, still queued → attempt recorded
expect "genuine no-ship, still queued → failed (attempt recorded)" "failed:" \
  "$(recon "{\"state\":\"OPEN\",\"labels\":[$READY]}" '{"comments":[]}')"
# D — stale sentinel from BEFORE the last re-queue must NOT suppress a real failure
expect "stale ralph-blocked (pre-requeue) → failed (attempt recorded)" "failed:" \
  "$(recon "{\"state\":\"OPEN\",\"labels\":[$READY]}" '{"comments":[{"body":"ralph-blocked: old","createdAt":"2026-07-10T00:00:00Z"}]}')"
# E — an OPEN/MERGED PR for the issue is always success, regardless of signals
expect "PR exists → pr:N (success)" "pr:" \
  "$(recon "{\"state\":\"OPEN\",\"labels\":[$READY]}" '{"comments":[]}' '[{"number":7,"headRefName":"ralph/issue-42-x","state":"MERGED"}]')"
# F — issue closed mid-run (human retracted) → no attempt burned
expect "issue closed mid-iteration → parked, no attempt" "parked:" \
  "$(recon '{"state":"CLOSED","labels":[{"name":"ralph-ready"}]}' '{"comments":[]}')"

echo "----"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
