#!/usr/bin/env bash
# Kit manifest (ralph#42): kit/MANIFEST.json is the one list of vendored kit
# files. scripts/kit-drift.sh compares a consumer's vendored ralph/ against
# an engine kit through it, so a new kit file can no longer escape the drift
# guard. Engine revisions without a manifest fall back to the legacy list.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

MANIFEST="$REPO_DIR/kit/MANIFEST.json"
DRIFT="$REPO_DIR/scripts/kit-drift.sh"

new_case manifest_matches_kit_dir
listed=$(jq -r '.kit[]' "$MANIFEST" 2>/dev/null | sort | tr '\n' ' ')
present=$(find "$REPO_DIR/kit" -maxdepth 1 -type f -exec basename {} \; | sort | tr '\n' ' ')
assert_eq "$present" "$listed" "every kit/ file is listed, and every listed file exists"
assert_eq 0 "$(jq -r '.perRepo[]' "$MANIFEST" | grep -cxF -f <(jq -r '.kit[]' "$MANIFEST"))" \
  "no file is both kit and per-repo"

# A consumer tree + an engine tree, both from the real kit.
mk_trees() {
  mkdir -p "$CASE/engine/kit" "$CASE/consumer"
  cp "$REPO_DIR"/kit/* "$CASE/engine/kit/"
  cp "$REPO_DIR"/kit/* "$CASE/consumer/"
}

new_case in_sync
mk_trees
out=$(bash "$DRIFT" "$CASE/consumer" "$CASE/engine/kit" 2>/dev/null) && rc=0 || rc=$?
assert_eq 0 "$rc" "exit 0"
assert_eq "" "$out" "nothing drifted"

new_case one_file_changed
mk_trees
echo "# local edit" >>"$CASE/consumer/next.sh"
out=$(bash "$DRIFT" "$CASE/consumer" "$CASE/engine/kit" 2>/dev/null)
assert_eq "next.sh" "$out" "the changed file is reported"

new_case new_kit_file_never_vendored
mk_trees
echo "new" >"$CASE/engine/kit/approver.sh"
jq '.kit += ["approver.sh"]' "$CASE/engine/kit/MANIFEST.json" >"$CASE/m" && mv "$CASE/m" "$CASE/engine/kit/MANIFEST.json"
out=$(bash "$DRIFT" "$CASE/consumer" "$CASE/engine/kit" 2>/dev/null | sort | tr '\n' ' ')
assert_eq "MANIFEST.json approver.sh " "$out" "a manifest file the consumer lacks is drift (the old guard skipped it)"

new_case per_repo_files_exempt
mk_trees
echo "custom" >"$CASE/consumer/gate.sh"
echo "X=1" >"$CASE/consumer/config.env"
echo "differs" >"$CASE/engine/kit/gate.sh"
out=$(bash "$DRIFT" "$CASE/consumer" "$CASE/engine/kit" 2>/dev/null)
assert_eq "" "$out" "gate.sh / config.env are never compared"

new_case no_manifest_uses_legacy_list
mk_trees
rm "$CASE/engine/kit/MANIFEST.json" "$CASE/consumer/MANIFEST.json"
echo "# edit" >>"$CASE/consumer/status.sh"
out=$(bash "$DRIFT" "$CASE/consumer" "$CASE/engine/kit" 2>"$CASE/err")
assert_eq "status.sh" "$out" "legacy list still compares the old six files"
assert_contains "$(cat "$CASE/err")" "legacy list" "the fallback is announced on stderr"

new_case legacy_list_skips_missing_vendored
mk_trees
rm "$CASE/engine/kit/MANIFEST.json" "$CASE/consumer/loop.sh"
out=$(bash "$DRIFT" "$CASE/consumer" "$CASE/engine/kit" 2>/dev/null)
assert_eq "" "$out" "legacy mode keeps the old rule: an unvendored file is not drift"

new_case malformed_manifest_falls_back
mk_trees
echo "{not json" >"$CASE/engine/kit/MANIFEST.json"
echo "# edit" >>"$CASE/consumer/lib.sh"
out=$(bash "$DRIFT" "$CASE/consumer" "$CASE/engine/kit" 2>"$CASE/err")
assert_eq "lib.sh" "$out" "a malformed manifest falls back to the legacy list"
assert_contains "$(cat "$CASE/err")" "legacy list" "and says so"

new_case gate_reads_the_manifest
WF="$REPO_DIR/.github/workflows/ralph-gate-reusable.yml"
STEP=$(awk '/- name: Kit drift check/{on=1;next} on && /- name: /{exit} on' "$WF")
assert_eq 1 "$(grep -c 'bash .engine-kit/scripts/kit-drift.sh ralph .engine-kit/kit' <<<"$STEP")" "the drift step calls scripts/kit-drift.sh"
assert_eq 0 "$(grep -c 'for f in lib.sh next.sh' <<<"$STEP")" "no hard-coded kit list left in the step"

new_case harness_vendors_from_manifest
for f in $(jq -r '.kit[]' "$MANIFEST"); do
  [ -f "$CASE/ralph/$f" ] || _fail "test sandbox lacks ralph/$f"
done
_ok "new_case vendors every manifest file"

report
