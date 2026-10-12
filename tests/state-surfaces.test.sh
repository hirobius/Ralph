#!/usr/bin/env bash
# State-surface registry gate tests (ralph#37, spec ops#576): scripts/check-state-surfaces.sh.
#
# THE MECHANISM. docs/state-surfaces.json lists every file that describes
# project state and what keeps it true. The gate fails when a registered path
# is gone, markdown names a path that does not exist, a generated surface's
# check command fails, or the registry is malformed; an editorial surface past
# its maxAgeDays is a "review due" WARNING (a date passing must not redden
# unrelated kit PRs) that --strict-review turns into a failure.
#
# Each case builds a throwaway repo root, so nothing here reads the real docs.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

GATE="$REPO_DIR/scripts/check-state-surfaces.sh"
TODAY=2026-10-12

new_root() { # <name> — empty root with a README and an existing docs file
  CASE_NAME=$1
  R=$(mktemp -d "${TMPDIR:-/tmp}/ralph-surfaces-XXXXXX")
  mkdir -p "$R/docs" "$R/kit"
  : >"$R/kit/lib.sh"
  printf '# Fixture\n\nSee `kit/lib.sh`.\n' >"$R/README.md"
}

registry() { # JSON on stdin
  cat >"$R/docs/state-surfaces.json"
}

gate() { # [args...]
  RUN_CODE=0
  RUN_OUT=$(bash "$GATE" --root "$R" --today "$TODAY" "$@" 2>&1) || RUN_CODE=$?
}

EDITORIAL_README='{"path":"README.md","describes":"prose","kind":"editorial","owner":"Adrian","reviewedAt":"2026-10-01","maxAgeDays":90}'

new_root clean
registry <<EOF2
{"surfaces":[$EDITORIAL_README,
  {"path":"kit/lib.sh","describes":"engine","kind":"checked","by":"kit/lib.sh"}]}
EOF2
gate
assert_eq 0 "$RUN_CODE" "a consistent registry passes"
assert_contains "$RUN_OUT" "1 checked, 1 editorial" "summary counts surfaces by kind"

new_root registry-missing
gate
assert_eq 1 "$RUN_CODE" "no registry fails"
assert_contains "$RUN_OUT" "REGISTRY_MISSING" "names REGISTRY_MISSING"

new_root registry-not-json
echo '{nope' | registry
gate
assert_eq 1 "$RUN_CODE" "malformed JSON fails"
assert_contains "$RUN_OUT" "REGISTRY_INVALID" "names REGISTRY_INVALID"

new_root registry-no-surfaces
echo '{"surfaces":{}}' | registry
gate
assert_eq 1 "$RUN_CODE" "surfaces must be an array"
assert_contains "$RUN_OUT" 'needs a "surfaces" array' "says what is missing"

new_root surface-missing
registry <<EOF2
{"surfaces":[{"path":"docs/gone.md","describes":"x","kind":"checked","by":"kit/lib.sh"}]}
EOF2
gate
assert_eq 1 "$RUN_CODE" "a registered path that does not exist fails"
assert_contains "$RUN_OUT" "SURFACE_MISSING" "names SURFACE_MISSING"
assert_contains "$RUN_OUT" "docs/gone.md" "names the path"

new_root by-missing
registry <<EOF2
{"surfaces":[{"path":"kit/lib.sh","describes":"x","kind":"generated","by":"scripts/not-here.sh"}]}
EOF2
gate
assert_eq 1 "$RUN_CODE" "a generator path that does not exist fails"
assert_contains "$RUN_OUT" "BY_MISSING" "names BY_MISSING"

new_root by-command-not-path
registry <<EOF2
{"surfaces":[{"path":"kit/lib.sh","describes":"x","kind":"checked","by":"a review gate"}]}
EOF2
gate
assert_eq 0 "$RUN_CODE" "a prose \"by\" is not treated as a path"

new_root invalid-fields
registry <<EOF2
{"surfaces":[
  {"path":"kit/lib.sh","describes":"x","kind":"generated"},
  {"path":"README.md","describes":"x","kind":"editorial","reviewedAt":"2026-02-30","maxAgeDays":0},
  {"path":"README.md","describes":"x","kind":"weird"}]}
EOF2
gate
assert_eq 1 "$RUN_CODE" "malformed entries fail"
assert_contains "$RUN_OUT" 'must name its generator' "a generated surface needs by"
assert_contains "$RUN_OUT" 'needs an "owner"' "an editorial surface needs an owner"
assert_contains "$RUN_OUT" 'calendar day' "2026-02-30 is not a calendar day"
assert_contains "$RUN_OUT" 'positive integer' "maxAgeDays must be a positive integer"
assert_contains "$RUN_OUT" 'kind must be one of' "kind is validated"

new_root future-review
registry <<EOF2
{"surfaces":[{"path":"README.md","describes":"x","kind":"editorial","owner":"Adrian","reviewedAt":"2026-10-14","maxAgeDays":90}]}
EOF2
gate
assert_eq 1 "$RUN_CODE" "a reviewedAt in the future fails"
assert_contains "$RUN_OUT" "in the future" "says why"
registry <<EOF2
{"surfaces":[{"path":"README.md","describes":"x","kind":"editorial","owner":"Adrian","reviewedAt":"2026-10-13","maxAgeDays":90}]}
EOF2
gate
assert_eq 0 "$RUN_CODE" "one day ahead is tolerated (a local date can lead UTC)"

new_root multiline-describes
registry <<EOF2
{"surfaces":[
  {"path":"README.md","describes":"first line\nsecond line\r\nthird line","kind":"editorial","owner":"Adrian","reviewedAt":"2026-10-01","maxAgeDays":90},
  {"path":"docs/gone.md","describes":"next surface\n\nstill parsed","kind":"checked","by":"kit/lib.sh"}]}
EOF2
gate
assert_eq 1 "$RUN_CODE" "a multi-line describes still fails only for the real problem"
assert_contains "$RUN_OUT" "SURFACE_MISSING" "the surface after a multi-line describes is read as its own row"
assert_contains "$RUN_OUT" "1 violation(s)" "no row is split into a phantom entry"
case $RUN_OUT in *'every surface needs a path'*) _fail "no phantom path-less row" ;; *) _ok "no phantom path-less row" ;; esac
registry <<EOF2
{"surfaces":[
  {"path":"README.md","describes":"first line\nsecond line","kind":"editorial","owner":"Adrian\nOwner","reviewedAt":"2026-10-01","maxAgeDays":90},
  {"path":"kit/lib.sh","describes":"engine\n","kind":"checked","by":"kit/lib.sh"}]}
EOF2
gate
assert_eq 0 "$RUN_CODE" "multi-line fields in editorial and checked rows pass"
assert_contains "$RUN_OUT" "1 checked, 1 editorial" "both rows are counted"

new_root duplicate
registry <<EOF2
{"surfaces":[$EDITORIAL_README,$EDITORIAL_README]}
EOF2
gate
assert_eq 1 "$RUN_CODE" "the same path+section registered twice fails"
assert_contains "$RUN_OUT" "registered twice" "says why"

new_root review-due-warns
registry <<EOF2
{"surfaces":[{"path":"README.md","describes":"x","kind":"editorial","owner":"Adrian","reviewedAt":"2026-06-01","maxAgeDays":30}]}
EOF2
gate
assert_eq 0 "$RUN_CODE" "an aged editorial surface warns without failing"
assert_contains "$RUN_OUT" "REVIEW_DUE" "names REVIEW_DUE"
assert_contains "$RUN_OUT" "Adrian re-reads it" "names who re-reads"
assert_contains "$RUN_OUT" "1 warning(s)" "counts the warning"
gate --strict-review
assert_eq 1 "$RUN_CODE" "--strict-review makes review-due fail"

new_root review-boundary
registry <<EOF2
{"surfaces":[{"path":"README.md","describes":"x","kind":"editorial","owner":"Adrian","reviewedAt":"2026-09-12","maxAgeDays":30}]}
EOF2
gate --strict-review
assert_eq 0 "$RUN_CODE" "exactly maxAgeDays old is still fresh"
gate --strict-review --today 2026-10-13
assert_eq 1 "$RUN_CODE" "one day older is due"

new_root dead-reference
printf '# Fixture\n\nSee `kit/lib.sh` and `kit/gone.sh`, [doc](docs/missing.md), [ok](kit/lib.sh).\n' >"$R/README.md"
registry <<EOF2
{"surfaces":[$EDITORIAL_README]}
EOF2
gate
assert_eq 1 "$RUN_CODE" "markdown naming a missing path fails"
assert_contains "$RUN_OUT" "README.md:3 DEAD_REFERENCE" "reports file:line and the rule"
assert_contains "$RUN_OUT" "kit/gone.sh" "backticked path is checked"
assert_contains "$RUN_OUT" "docs/missing.md" "link target is checked"
assert_contains "$RUN_OUT" "2 violation(s)" "the existing paths are not reported"

new_root dead-reference-skips
cat >"$R/README.md" <<'EOF2'
# Fixture

```sh
cat kit/in-a-fence.sh
```

Not paths: `https://example.com/a.md`, `kit/*.sh`, `<repo>/ralph/x.sh`, `cp -r a/b.sh c`,
`ralph/lib.sh`, `v1`, `kit/`, [anchor](#top), [mail](mailto:a@b.c), [site](https://x.y/z.md).
`kit/lib.sh:12` keeps its line suffix off.
EOF2
registry <<EOF2
{"ignoreReferences":["ralph/"],"surfaces":[$EDITORIAL_README]}
EOF2
gate
assert_eq 0 "$RUN_CODE" "fences, urls, globs, placeholders, commands, bare words and ignored prefixes are skipped"

new_root dead-reference-ignore
printf 'See `ralph/gate.sh`.\n' >"$R/README.md"
registry <<EOF2
{"surfaces":[$EDITORIAL_README]}
EOF2
gate
assert_eq 1 "$RUN_CODE" "without ignoreReferences a consumer-only path is dead"
registry <<EOF2
{"ignoreReferences":["ralph/"],"surfaces":[$EDITORIAL_README]}
EOF2
gate
assert_eq 0 "$RUN_CODE" "ignoreReferences clears it"

new_root dead-reference-relative
mkdir -p "$R/docs/sub"
printf 'x\n' >"$R/docs/sub/a.txt"
printf 'See [a](sub/a.txt) and `docs/sub/a.txt`.\n' >"$R/docs/NOTES.md"
printf '# Fixture\n' >"$R/README.md"
registry <<EOF2
{"surfaces":[{"path":"docs","describes":"notes","kind":"editorial","owner":"A","reviewedAt":"2026-10-01","maxAgeDays":90}]}
EOF2
gate
assert_eq 0 "$RUN_CODE" "a link resolves from its own directory or the repo root; directories register their markdown"
printf 'See [b](sub/b.txt).\n' >"$R/docs/NOTES.md"
gate
assert_contains "$RUN_OUT" "docs/NOTES.md:1 DEAD_REFERENCE" "markdown inside a registered directory is scanned"

new_root generated-not-scanned
printf 'See `kit/gone.sh`.\n' >"$R/GEN.md"
printf '# Fixture\n' >"$R/README.md"
registry <<EOF2
{"surfaces":[{"path":"GEN.md","describes":"x","kind":"generated","by":"kit/lib.sh"}]}
EOF2
gate
assert_eq 0 "$RUN_CODE" "a generated file belongs to its generator, not the reference scan"

new_root run-checks
registry <<EOF2
{"surfaces":[{"path":"kit/lib.sh","describes":"x","kind":"generated","by":"kit/lib.sh","check":"test -f nope"}]}
EOF2
gate
assert_eq 0 "$RUN_CODE" "check commands do not run without --run-checks"
gate --run-checks
assert_eq 1 "$RUN_CODE" "a failing check command fails under --run-checks"
assert_contains "$RUN_OUT" "GENERATED_STALE" "names GENERATED_STALE"
registry <<EOF2
{"surfaces":[{"path":"kit/lib.sh","describes":"x","kind":"generated","by":"kit/lib.sh","check":"test -f kit/lib.sh"}]}
EOF2
gate --run-checks
assert_eq 0 "$RUN_CODE" "a passing check command passes (it runs from the root)"

new_root bad-today
registry <<EOF2
{"surfaces":[$EDITORIAL_README]}
EOF2
gate --today 2026-13-01
assert_eq 2 "$RUN_CODE" "an impossible --today is a usage error"

report
