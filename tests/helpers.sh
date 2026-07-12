#!/usr/bin/env bash
# shellcheck shell=bash
# Shared harness for the kit tests: sandbox setup + assertions. Each test case
# gets a fresh temp dir with the kit vendored under ralph/ (exactly how
# consumers run it), stub gh/git on PATH, and an empty mutation log.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
ORIG_PATH="$PATH"
PASS=0
FAIL=0
CASE=""
CASE_NAME=""

new_case() { # <name>
  CASE_NAME=$1
  CASE=$(mktemp -d "${TMPDIR:-/tmp}/ralph-test-XXXXXX")
  mkdir -p "$CASE/ralph" "$CASE/fixtures"
  cp "$REPO_DIR"/kit/*.sh "$REPO_DIR/kit/prompt.md" "$CASE/ralph/"
  export GH_FIX_DIR="$CASE/fixtures"
  export GH_MUT_LOG="$CASE/mutations.log"
  : >"$GH_MUT_LOG"
  export GITHUB_REPOSITORY="hirobius/test"
  export PATH="$TESTS_DIR/stubs:$ORIG_PATH"
  unset GH_FAIL_PATTERNS GIT_CLAIM_REFS
}

fixture() { # <file>  (content on stdin)
  cat >"$GH_FIX_DIR/$1"
}

_ok() {
  PASS=$((PASS + 1))
  echo "  ok - $CASE_NAME: $1"
}

_fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL - $CASE_NAME: $1" >&2
  [ -n "${2:-}" ] && echo "         $2" >&2
}

assert_eq() { # <expected> <actual> <label>
  if [ "$1" = "$2" ]; then _ok "$3"; else _fail "$3" "expected '$1', got '$2'"; fi
}

assert_contains() { # <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then _ok "$3"; else _fail "$3" "'$2' not found in: $1"; fi
}

assert_mutation() { # <needle> <label> — mutation log contains needle
  if grep -qF -- "$1" "$GH_MUT_LOG"; then _ok "$2"; else
    _fail "$2" "no mutation matching '$1' in: $(cat "$GH_MUT_LOG")"
  fi
}

assert_no_mutation() { # <needle> <label>
  if grep -qF -- "$1" "$GH_MUT_LOG"; then
    _fail "$2" "unexpected mutation matching '$1': $(grep -F -- "$1" "$GH_MUT_LOG")"
  else _ok "$2"; fi
}

report() {
  echo
  echo "$PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}
