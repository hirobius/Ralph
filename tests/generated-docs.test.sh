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

# ── AGENTS.md front door ────────────────────────────────────────────────
write_registry() {
  cat >"$R/docs/state-surfaces.json" <<'EOF2'
{"surfaces":[
 {"path":"AGENTS.md","describes":"The front door","kind":"generated","by":"scripts/generate-agents-md.sh"},
 {"path":"README.md","describes":"Prose","kind":"editorial","owner":"Adrian","reviewedAt":"2026-10-01","maxAgeDays":90,"section":"prose"},
 {"path":"README.md","describes":"Test list","kind":"generated","by":"scripts/generate-readme-tests.sh","section":"ralph:tests"},
 {"path":"kit/status.sh","describes":"Live snapshot","kind":"generated","by":"kit/status.sh"},
 {"path":"tests","describes":"Suites","kind":"checked","by":"tests/run.sh"}
]}
EOF2
}

new_root agents-front-door
write_registry
run "$AGENTS_GEN"
assert_eq 0 "$RUN_CODE" "generation succeeds with no AGENTS.md yet"
AGENTS=$(cat "$R/AGENTS.md")
assert_contains "$AGENTS" '# AGENTS.md: Ralph' "titled for Ralph"
assert_contains "$AGENTS" 'autonomous issue-to-PR loop engine' "says what Ralph is in one line"
assert_contains "$AGENTS" '## Read order' "has a read order"
assert_contains "$AGENTS" '`bash tests/run.sh`' "names the test command"
assert_contains "$AGENTS" 'https://hirobius-ops-adrian-6234s-projects.vercel.app/ops/standing' "points at live state in ops"
assert_contains "$AGENTS" '`kit/status.sh`' "points at the loop snapshot"
assert_contains "$AGENTS" '### Generated' "indexes generated documents"
assert_contains "$AGENTS" '### Checked' "indexes checked documents"
assert_contains "$AGENTS" '### Editorial' "indexes editorial documents"
assert_contains "$AGENTS" '- `README.md` (prose): Prose. Adrian, reviewed 2026-10-01, re-read within 90 days.' "editorial rows print owner and review date"
assert_contains "$AGENTS" '- `README.md` (ralph:tests): Test list. Built by `scripts/generate-readme-tests.sh`.' "generated rows name their generator and section"
assert_contains "$AGENTS" '- `tests`: Suites. Checked by `tests/run.sh`.' "checked rows name their gate"
assert_contains "$AGENTS" '- `kit/status.sh`: Live snapshot. Generated at runtime.' "a runtime-generated surface says so"
run "$AGENTS_GEN" --check
assert_eq 0 "$RUN_CODE" "--check passes right after generating"
case $AGENTS in *[0-9].[0-9].[0-9]*) _fail "no version numbers in the front door" ;; *) _ok "no version numbers in the front door" ;; esac

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
sed -i 's/Ralph is the org-level/Ralph is the/' "$R/AGENTS.md"
run "$AGENTS_GEN" --check
assert_eq 1 "$RUN_CODE" "a hand edit inside the generated block is stale"

new_root agents-no-registry
run "$AGENTS_GEN"
assert_eq 1 "$RUN_CODE" "no registry is an error"
assert_contains "$RUN_OUT" "state-surfaces.json" "names the registry"
[ ! -e "$R/AGENTS.md" ] && _ok "nothing is written" || _fail "nothing is written"

report
