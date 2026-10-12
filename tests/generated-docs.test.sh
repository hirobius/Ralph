#!/usr/bin/env bash
# Generated-docs tests (ralph#37, spec ops#576): scripts/generate-readme-tests.sh
# (README's test list from tests/*.test.sh) and scripts/generate-agents-md.sh
# (the AGENTS.md front door from docs/state-surfaces.json).
#
# THE MECHANISM. Both generators are deterministic and have a --check: the
# README can neither name a suite that is gone nor miss a new one, and
# AGENTS.md cannot drift from the registry. Hand-written text outside the
# generated block (README prose; notes after the AGENTS.md end marker) must
# survive a regeneration byte for byte.
#
# Each case builds a throwaway repo root, so nothing here touches the real docs.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

README_GEN="$REPO_DIR/scripts/generate-readme-tests.sh"
AGENTS_GEN="$REPO_DIR/scripts/generate-agents-md.sh"

new_root() { # <name>
  CASE_NAME=$1
  R=$(mktemp -d "${TMPDIR:-/tmp}/ralph-gen-XXXXXX")
  mkdir -p "$R/tests" "$R/docs"
  cat >"$R/docs/agents-intro.md" <<'EOF2'
# AGENTS.md: Fixture

Fixture is a loop engine. Read `README.md`, then run `bash tests/run.sh`.

Live state is the ops dashboard's `/ops/standing`; run `kit/status.sh` for one loop.
EOF2
}

suite() { # <name> <header-comment-lines...>
  local name=$1
  shift
  {
    echo '#!/usr/bin/env bash'
    printf '# %s\n' "$@"
    echo 'set -uo pipefail'
  } >"$R/tests/$name.test.sh"
}

run() { # <script> [args...]
  local script=$1
  shift
  RUN_CODE=0
  RUN_OUT=$(bash "$script" --root "$R" "$@" 2>&1) || RUN_CODE=$?
}

readme_with_markers() {
  {
    printf '# Fixture\n\nIntro stays.\n\n'
    printf '%s\n%s\n' \
      '<!-- ralph:tests:start — generated from tests/*.test.sh by scripts/generate-readme-tests.sh; do not hand-edit until the end marker. -->' \
      '<!-- ralph:tests:end -->'
    printf '\nOutro stays.\n'
  } >"$R/README.md"
}

# ── README test list ────────────────────────────────────────────────────
new_root readme-list
suite alpha 'Alpha decision table for the selector (ops#1). More detail follows here.' '' 'Second paragraph is ignored.'
suite beta 'shellcheck shell=bash' 'Beta wraps its first' 'sentence over two lines. And a second sentence.'
suite gamma 'Gamma has one word then a very long run-on description that never ends and keeps going well past the cap that the README list keeps so that one verbose suite header cannot flood the page.'
readme_with_markers
run "$README_GEN"
assert_eq 0 "$RUN_CODE" "generation succeeds"
README=$(cat "$R/README.md")
assert_contains "$README" '- `tests/alpha.test.sh`: Alpha decision table for the selector (ops#1).' "first sentence of the header comment"
assert_contains "$README" '- `tests/beta.test.sh`: Beta wraps its first sentence over two lines.' "a wrapped sentence is joined; shellcheck directive lines are skipped"
assert_contains "$README" '- `tests/gamma.test.sh`: Gamma has one word' "long header is kept to its start"
case $README in *'cannot flood'*) _fail "a long header is capped" ;; *) _ok "a long header is capped" ;; esac
assert_contains "$README" '...' "a capped header ends in an ellipsis"
case $README in *'Second paragraph'*) _fail "only the first paragraph is used" ;; *) _ok "only the first paragraph is used" ;; esac
assert_contains "$README" 'Intro stays.' "prose before the block survives"
assert_contains "$README" 'Outro stays.' "prose after the block survives"
first=$(grep -n 'alpha.test.sh' "$R/README.md" | cut -d: -f1)
last=$(grep -n 'gamma.test.sh' "$R/README.md" | cut -d: -f1)
[ "$first" -lt "$last" ] && _ok "suites are listed in name order" || _fail "suites are listed in name order"
run "$README_GEN" --check
assert_eq 0 "$RUN_CODE" "--check passes right after generating"
before=$(cat "$R/README.md")
run "$README_GEN"
assert_eq "$before" "$(cat "$R/README.md")" "regenerating is idempotent"

suite delta 'Delta is a new suite.'
run "$README_GEN" --check
assert_eq 1 "$RUN_CODE" "--check fails when a suite is added"
assert_contains "$RUN_OUT" "out of date" "says the list is stale"
assert_contains "$RUN_OUT" "generate-readme-tests.sh" "names the fix"
run "$README_GEN"
run "$README_GEN" --check
assert_eq 0 "$RUN_CODE" "regenerating clears it"
assert_contains "$(cat "$R/README.md")" 'tests/delta.test.sh' "the new suite is listed"

rm "$R/tests/alpha.test.sh"
run "$README_GEN" --check
assert_eq 1 "$RUN_CODE" "--check fails when a suite is removed"

new_root readme-edge-headers
suite abbrev 'Pick one, e.g. the oldest, then stop. Second sentence.'
suite paren 'Handles (i.e. exactly) one case. Next.'
printf '#!/usr/bin/env bash\nset -uo pipefail\n' >"$R/tests/bare.test.sh"
printf '#!/usr/bin/env bash\n# shellcheck shell=bash\n\nset -uo pipefail\n' >"$R/tests/directive-only.test.sh"
readme_with_markers
run "$README_GEN"
assert_eq 0 "$RUN_CODE" "generation succeeds with headerless suites"
README=$(cat "$R/README.md")
assert_contains "$README" '- `tests/abbrev.test.sh`: Pick one, e.g. the oldest, then stop.' "e.g. does not end the sentence"
assert_contains "$README" '- `tests/paren.test.sh`: Handles (i.e. exactly) one case.' "(i.e. ...) does not end the sentence"
assert_contains "$README" '- `tests/bare.test.sh`' "a headerless suite is still listed"
case $README in *'bare.test.sh`: .'*|*'directive-only.test.sh`: .'*) _fail "no lone period for a headerless suite" ;; *) _ok "no lone period for a headerless suite" ;; esac
case $README in *'bare.test.sh`:'*|*'directive-only.test.sh`:'*) _fail "no empty description after the colon" ;; *) _ok "no empty description after the colon" ;; esac
run "$README_GEN" --check
assert_eq 0 "$RUN_CODE" "--check passes with headerless suites"

new_root readme-trailing-newline
suite alpha 'Alpha.'
readme_with_markers
run "$README_GEN"
[ -z "$(tail -c1 "$R/README.md")" ] && _ok "a README that ends with a newline still does" || _fail "a README that ends with a newline still does"
printf 'no final newline' >>"$R/README.md"
run "$README_GEN"
assert_eq "no final newline" "$(tail -c16 "$R/README.md")" "a README with no final newline is not given one"
run "$README_GEN" --check
assert_eq 0 "$RUN_CODE" "--check agrees with the preserved ending"

new_root readme-no-markers
suite alpha 'Alpha.'
printf '# Fixture\n' >"$R/README.md"
run "$README_GEN"
assert_eq 1 "$RUN_CODE" "no markers is an error"
assert_contains "$RUN_OUT" "ralph:tests" "names the missing markers"
assert_eq '# Fixture' "$(cat "$R/README.md")" "the README is left untouched"

new_root readme-hand-edit
suite alpha 'Alpha.'
readme_with_markers
run "$README_GEN"
sed -i 's/Alpha\./Hand edited./' "$R/README.md"
run "$README_GEN" --check
assert_eq 1 "$RUN_CODE" "a hand edit inside the block is stale"

# A long header with a multibyte character must cut at the same place in any
# locale: bash counts bytes under C/POSIX and characters under UTF-8 (CI).
new_root readme-locale
suite epsilon 'Epsilon — a header with an em dash and enough words that it runs well past the one hundred and forty character cap set for the README list.'
readme_with_markers
RUN_CODE=0; LC_ALL=C bash "$README_GEN" --root "$R" >/dev/null 2>&1 || RUN_CODE=$?
assert_eq 0 "$RUN_CODE" "generation succeeds under LC_ALL=C"
c_out=$(cat "$R/README.md")
RUN_CODE=0; LC_ALL=C.UTF-8 bash "$README_GEN" --root "$R" --check >/dev/null 2>&1 || RUN_CODE=$?
assert_eq 0 "$RUN_CODE" "a list generated under LC_ALL=C passes --check under C.UTF-8"
RUN_CODE=0; LC_ALL=C.UTF-8 bash "$README_GEN" --root "$R" >/dev/null 2>&1 || RUN_CODE=$?
assert_eq "$c_out" "$(cat "$R/README.md")" "C and C.UTF-8 produce the same list"

# ── AGENTS.md front door ────────────────────────────────────────────────
write_registry() {
  cat >"$R/docs/state-surfaces.json" <<'EOF2'
{"surfaces":[
 {"path":"AGENTS.md","describes":"The front door","kind":"generated","by":"scripts/generate-agents-md.sh"},
 {"path":"README.md","describes":"Prose","kind":"editorial","owner":"Adrian","reviewedAt":"2026-10-01","maxAgeDays":90,"section":"prose"},
 {"path":"README.md","describes":"Test list","kind":"generated","by":"scripts/generate-readme-tests.sh","section":"ralph:tests"},
 {"path":"docs/agents-intro.md","describes":"The hand-written intro","kind":"editorial","owner":"Adrian","reviewedAt":"2026-10-01","maxAgeDays":90},
 {"path":"kit/status.sh","describes":"Live snapshot","kind":"checked","by":"tests/parked-prs.test.sh"},
 {"path":"tests","describes":"Suites","kind":"checked","by":"tests/run.sh"}
]}
EOF2
}

new_root agents-front-door
write_registry
run "$AGENTS_GEN"
assert_eq 0 "$RUN_CODE" "generation succeeds with no AGENTS.md yet"
AGENTS=$(cat "$R/AGENTS.md")
assert_contains "$AGENTS" '# AGENTS.md: Fixture' "the hand-written intro opens the file"
assert_contains "$AGENTS" 'Fixture is a loop engine. Read `README.md`, then run `bash tests/run.sh`.' "the intro file is included verbatim"
case $AGENTS in *vercel.app*|*https://*) _fail "no ops host baked into the generator" ;; *) _ok "no ops host baked into the generator" ;; esac
case $(cat "$AGENTS_GEN") in *vercel.app*) _fail "the generator names no ops host" ;; *) _ok "the generator names no ops host" ;; esac
case $AGENTS in *'The hand-written intro'*) _ok "the intro file is indexed as editorial" ;; *) _fail "the intro file is indexed as editorial" ;; esac
assert_contains "$AGENTS" '### Generated' "indexes generated documents"
assert_contains "$AGENTS" '### Checked' "indexes checked documents"
assert_contains "$AGENTS" '### Editorial' "indexes editorial documents"
assert_contains "$AGENTS" '- `README.md` (prose): Prose. Adrian, reviewed 2026-10-01, re-read within 90 days.' "editorial rows print owner and review date"
assert_contains "$AGENTS" '- `README.md` (ralph:tests): Test list. Built by `scripts/generate-readme-tests.sh`.' "generated rows name their generator and section"
assert_contains "$AGENTS" '- `tests`: Suites. Checked by `tests/run.sh`.' "checked rows name their gate"
assert_contains "$AGENTS" '- `kit/status.sh`: Live snapshot. Checked by `tests/parked-prs.test.sh`.' "a script is checked by the test that exercises it, not generated by itself"
case $AGENTS in *'Generated at runtime'*) _fail "no self-generated rows" ;; *) _ok "no self-generated rows" ;; esac
case $AGENTS in *'Hand-kept'*) _fail "the checked gloss does not call code hand-kept" ;; *) _ok "the checked gloss does not call code hand-kept" ;; esac
run "$AGENTS_GEN" --check
assert_eq 0 "$RUN_CODE" "--check passes right after generating"
case $AGENTS in *[0-9].[0-9].[0-9]*) _fail "no version numbers in the front door" ;; *) _ok "no version numbers in the front door" ;; esac

new_root agents-intro-edit
write_registry
run "$AGENTS_GEN"
printf '\nA new rule.\n' >>"$R/docs/agents-intro.md"
run "$AGENTS_GEN" --check
assert_eq 1 "$RUN_CODE" "editing the intro file makes AGENTS.md stale until regenerated"
run "$AGENTS_GEN"
assert_contains "$(cat "$R/AGENTS.md")" 'A new rule.' "regeneration picks up the intro edit"

new_root agents-no-intro
write_registry
rm "$R/docs/agents-intro.md"
run "$AGENTS_GEN"
assert_eq 1 "$RUN_CODE" "a missing intro file is an error"
assert_contains "$RUN_OUT" "agents-intro.md" "names the intro file"
[ ! -e "$R/AGENTS.md" ] && _ok "nothing is written without the intro" || _fail "nothing is written without the intro"

new_root agents-multiline-describes
cat >"$R/docs/state-surfaces.json" <<'EOF2'
{"surfaces":[{"path":"README.md","describes":"Prose\nover two lines","kind":"editorial","owner":"A","reviewedAt":"2026-10-01","maxAgeDays":9},
 {"path":"tests","describes":"Suites","kind":"checked","by":"tests/run.sh"}]}
EOF2
run "$AGENTS_GEN"
AGENTS=$(cat "$R/AGENTS.md")
assert_contains "$AGENTS" '- `README.md`: Prose over two lines. A, reviewed' "a multi-line describes stays on one list line"
assert_contains "$AGENTS" '- `tests`: Suites. Checked by `tests/run.sh`.' "the row after it is intact"

new_root agents-kind-absent
cat >"$R/docs/state-surfaces.json" <<'EOF2'
{"surfaces":[{"path":"README.md","describes":"Prose","kind":"editorial","owner":"A","reviewedAt":"2026-10-01","maxAgeDays":9}]}
EOF2
run "$AGENTS_GEN"
AGENTS=$(cat "$R/AGENTS.md")
case $AGENTS in *'### Generated'*) _fail "a kind with no rows prints no heading" ;; *) _ok "a kind with no rows prints no heading" ;; esac

new_root agents-notes-survive
write_registry
run "$AGENTS_GEN"
printf '\n## Hand notes\n\nKeep me.\n' >>"$R/AGENTS.md"
before=$(cat "$R/AGENTS.md")
run "$AGENTS_GEN" --check
assert_eq 0 "$RUN_CODE" "hand-written notes after the end marker do not make it stale"
run "$AGENTS_GEN"
assert_eq "$before" "$(cat "$R/AGENTS.md")" "regenerating keeps the notes byte for byte"

new_root agents-trailing-bytes
write_registry
run "$AGENTS_GEN"
[ -z "$(tail -c1 "$R/AGENTS.md")" ] && _ok "a fresh AGENTS.md ends with a newline" || _fail "a fresh AGENTS.md ends with a newline"
printf '\n## Notes\n\nKeep.\n\n\n' >>"$R/AGENTS.md"
before=$(cksum <"$R/AGENTS.md")
run "$AGENTS_GEN"
assert_eq "$before" "$(cksum <"$R/AGENTS.md")" "trailing blank lines after the end marker survive byte for byte"

new_root agents-stale
write_registry
run "$AGENTS_GEN"
sed -i 's/"reviewedAt":"2026-10-01"/"reviewedAt":"2026-10-12"/' "$R/docs/state-surfaces.json"
run "$AGENTS_GEN" --check
assert_eq 1 "$RUN_CODE" "bumping reviewedAt makes AGENTS.md stale until regenerated"
assert_contains "$RUN_OUT" "generate-agents-md.sh" "names the fix"
run "$AGENTS_GEN"
assert_contains "$(cat "$R/AGENTS.md")" 'reviewed 2026-10-12' "regeneration prints the new review date"

new_root agents-hand-edit
write_registry
run "$AGENTS_GEN"
sed -i 's/Fixture is a loop engine/Fixture is an engine/' "$R/AGENTS.md"
run "$AGENTS_GEN" --check
assert_eq 1 "$RUN_CODE" "a hand edit inside the generated block is stale"

new_root agents-no-registry
run "$AGENTS_GEN"
assert_eq 1 "$RUN_CODE" "no registry is an error"
assert_contains "$RUN_OUT" "state-surfaces.json" "names the registry"
[ ! -e "$R/AGENTS.md" ] && _ok "nothing is written" || _fail "nothing is written"

report
