#!/usr/bin/env bash
# kit-lock.sh (ralph#42): consumers pin their vendored kit in
# ralph/kit.lock.json ({"ref":..., "files":{name: sha256}}, ops#492/#568).
# The engine generates that lock from kit/MANIFEST.json, so the lock's file
# list and the drift guard's file list are the same list.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

LOCK="$REPO_DIR/scripts/kit-lock.sh"

new_case lock_shape
out=$(bash "$LOCK" hirobius/ralph@v2) && rc=0 || rc=$?
assert_eq 0 "$rc" "exit 0"
assert_eq "hirobius/ralph@v2" "$(jq -r .ref <<<"$out")" "ref is recorded as given"
assert_eq "$(jq -r '.kit | join(" ")' "$REPO_DIR/kit/MANIFEST.json")" "$(jq -r '.files | keys_unsorted | join(" ")' <<<"$out")" \
  "files are exactly the manifest's kit list, in its order"
want=$(if command -v sha256sum >/dev/null; then sha256sum "$REPO_DIR/kit/lib.sh"; else shasum -a 256 "$REPO_DIR/kit/lib.sh"; fi | cut -d' ' -f1)
assert_eq "$want" "$(jq -r '.files["lib.sh"]' <<<"$out")" "each value is the file's sha256"
assert_eq 0 "$(jq -r '.files | keys[]' <<<"$out" | grep -cxE 'gate.sh|config.env|README.md|post-close.sh')" "no per-repo file is pinned"

new_case kit_dir_argument
mkdir -p "$CASE/k"
cp "$REPO_DIR"/kit/* "$CASE/k/"
echo "# changed" >>"$CASE/k/next.sh"
a=$(bash "$LOCK" x "$CASE/k" | jq -r '.files["next.sh"]')
b=$(bash "$LOCK" x | jq -r '.files["next.sh"]')
assert_eq 1 "$([ "$a" != "$b" ] && echo 1 || echo 0)" "an explicit kit dir is hashed instead of this repo's kit/"

new_case no_manifest_fails
mkdir -p "$CASE/empty"
bash "$LOCK" x "$CASE/empty" >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 1 "$rc" "a kit dir without a manifest is an error, not an empty lock"

report
