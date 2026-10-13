#!/usr/bin/env bash
# How Ralph Decides doc generator tests: scripts/generate-how-ralph-decides.sh
# (docs/HOW-RALPH-DECIDES.md generated from kit/lib.sh decision tables).
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

GEN="$REPO_DIR/scripts/generate-how-ralph-decides.sh"

new_root() { # <name>
  CASE_NAME=$1
  R=$(mktemp -d "${TMPDIR:-/tmp}/ralph-decides-XXXXXX")
  mkdir -p "$R/kit" "$R/docs"
  cp -r "$REPO_DIR/kit/"* "$R/kit/"
}

run() { # <script> [args...]
  local script=$1
  shift
  RUN_CODE=0
  RUN_OUT=$(bash "$script" --root "$R" "$@" 2>&1) || RUN_CODE=$?
}

# ── 1. Generation & --check on missing / stale ─────────────────────────────
new_root fresh-gen
run "$GEN" --check
assert_eq 1 "$RUN_CODE" "--check fails when HOW-RALPH-DECIDES.md is missing"

run "$GEN"
assert_eq 0 "$RUN_CODE" "generation succeeds"
[ -f "$R/docs/HOW-RALPH-DECIDES.md" ] && _ok "docs/HOW-RALPH-DECIDES.md created" || _fail "docs/HOW-RALPH-DECIDES.md created"

OUT1=$(cat "$R/docs/HOW-RALPH-DECIDES.md")
run "$GEN" --check
assert_eq 0 "$RUN_CODE" "--check passes when file is up to date"

run "$GEN"
assert_eq 0 "$RUN_CODE" "regenerating succeeds"
OUT2=$(cat "$R/docs/HOW-RALPH-DECIDES.md")
assert_eq "$OUT1" "$OUT2" "generation is deterministic"

printf '\nHand edit.\n' >>"$R/docs/HOW-RALPH-DECIDES.md"
run "$GEN" --check
assert_eq 1 "$RUN_CODE" "--check fails when file is stale"

# ── 2. All ralph_approver_reason codes appear ──────────────────────────────
new_root codes-check
run "$GEN"
assert_eq 0 "$RUN_CODE" "generation succeeds"
OUT=$(cat "$R/docs/HOW-RALPH-DECIDES.md")

# Ensure marker is present at start
assert_contains "$OUT" "generated — do not hand-edit" "starts with generated do-not-hand-edit marker"
assert_contains "$OUT" "generate-how-ralph-decides.sh" "marker names the script"

CODES=(
  gate-red
  unreadable-facts
  rework-exhausted
  no-review
  supervised-path
  security-finding
  reviewer-disagreement
  approver-unavailable
  approver-escalated
  policy-clear
)

for code in "${CODES[@]}"; do
  assert_contains "$OUT" "$code" "output contains code $code"
done

# ── 3. Priority order & supervised path statement ──────────────────────────
assert_contains "$OUT" "ralph-approved" "lists arm reason ralph-approved"
assert_contains "$OUT" "issue ralph-auto" "lists arm reason issue ralph-auto"
assert_contains "$OUT" "approver" "lists arm reason approver"
assert_contains "$OUT" "default posture" "lists arm reason default posture"
assert_contains "$OUT" "supervised-path" "mentions supervised-path diff blocking arming"

# ── 4. Fixture with extra row/code changes output ──────────────────────────
new_root extra-code-fixture
run "$GEN"
BASE_OUT=$(cat "$R/docs/HOW-RALPH-DECIDES.md")

# Modify fixture kit/lib.sh to add an 11th row in the decision table comment
# and a new code in ralph_approver_reason
sed -i '/10 otherwise/a #   11 extra-condition                             → escalate extra-code' "$R/kit/lib.sh"
sed -i '/policy-clear)/a \    extra-code) echo "Extra test reason sentence." ;;' "$R/kit/lib.sh"

run "$GEN"
assert_eq 0 "$RUN_CODE" "generation succeeds on fixture with extra row/code"
EXTRA_OUT=$(cat "$R/docs/HOW-RALPH-DECIDES.md")

assert_contains "$EXTRA_OUT" "extra-code" "output contains extra code"
assert_contains "$EXTRA_OUT" "Extra test reason sentence." "output contains extra reason sentence"
if [ "$BASE_OUT" != "$EXTRA_OUT" ]; then
  _ok "fixture with extra row/code changes the output"
else
  _fail "fixture with extra row/code changes the output"
fi

report
