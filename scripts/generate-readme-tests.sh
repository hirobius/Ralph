#!/usr/bin/env bash
# Generate README's test list from tests/*.test.sh (hirobius/ralph#37, spec
# hirobius/ops#576). The list lives between the ralph:tests markers in
# README.md; the description of each suite is the first sentence of its header
# comment, so the README cannot name a suite that is gone or miss a new one.
#
# Usage:
#   bash scripts/generate-readme-tests.sh            rewrite the marked section
#   bash scripts/generate-readme-tests.sh --check    exit 1 when it is stale
#   --root <dir>   read and write under <dir> instead of the repo (tests)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$HERE/lib.sh"

ROOT=$(dirname "$HERE")
CHECK=0
while [ $# -gt 0 ]; do
  case $1 in
    --check) CHECK=1 ;;
    --root)
      ROOT=$(cd "${2:?--root needs a directory}" && pwd)
      shift
      ;;
    *)
      echo "usage: generate-readme-tests.sh [--check] [--root <dir>]" >&2
      exit 2
      ;;
  esac
  shift
done

README_PATH=README.md
TESTS_START='<!-- ralph:tests:start — generated from tests/*.test.sh by scripts/generate-readme-tests.sh; do not hand-edit until the end marker. -->'
TESTS_END='<!-- ralph:tests:end -->'

# first_sentence <text> — <text> up to its first sentence end: a period followed
# by a space, unless the word it closes is an abbreviation (e.g. i.e. cf. vs.).
first_sentence() {
  local rest=$1 acc='' head word
  while :; do
    case $rest in
      *". "*) ;;
      *)
        acc+=$rest
        break
        ;;
    esac
    head=${rest%%". "*}
    word=${head##* }
    word=${word#\(}
    case ${word,,} in
      e.g | i.e | cf | vs)
        acc+="$head. "
        rest=${rest#*". "}
        ;;
      *)
        acc+=$head
        break
        ;;
    esac
  done
  printf '%s' "$acc"
}

# suite_summary <file> — the first sentence of the file's header comment (the
# comment paragraph after the shebang), at most 140 characters (cut at a word,
# then "..."), ending in sentence punctuation. Prints nothing when the file has
# no header comment.
suite_summary() {
  local text
  text=$(awk '
    NR == 1 && /^#!/ { next }
    /^# *shellcheck/ { next }
    /^#/ {
      t = $0; sub(/^# ?/, "", t)
      if (t == "") { if (got) exit; next }
      got = 1; text = text (text == "" ? "" : " ") t; next
    }
    { exit }
    END { print text }' "$1")
  text=$(first_sentence "$text")
  [ -n "$text" ] || return 0
  if ((${#text} > 140)); then
    text=${text:0:137}
    text="${text% *}..."
  fi
  case $text in
    *[.?!]) ;;
    *) text="$text." ;;
  esac
  printf '%s' "$text"
}

build_block() {
  local f name summary any=0
  printf '%s\n\n' "$TESTS_START"
  while IFS= read -r f; do
    any=1
    name=${f#"$ROOT"/}
    summary=$(suite_summary "$f")
    if [ -n "$summary" ]; then
      printf -- '- `%s`: %s\n' "$name" "$summary"
    else
      printf -- '- `%s`\n' "$name"
    fi
  done < <(find "$ROOT/tests" -maxdepth 1 -name '*.test.sh' -type f | LC_ALL=C sort)
  if [ "$any" -eq 0 ]; then printf '(no suites)\n'; fi
  printf '\n%s' "$TESTS_END"
}

[ -f "$ROOT/$README_PATH" ] || {
  echo "x $README_PATH is missing" >&2
  exit 1
}
current=''
next=''
read_file current "$ROOT/$README_PATH"
if ! replace_block next "$current" "$TESTS_START" "$TESTS_END" "$(build_block)"; then
  echo "x $README_PATH has no ralph:tests start/end markers; add them where the test list belongs." >&2
  exit 1
fi

if [ "$CHECK" -eq 1 ]; then
  if [ "$current" != "$next" ]; then
    echo "x $README_PATH test list is out of date with tests/*.test.sh. Run: bash scripts/generate-readme-tests.sh" >&2
    exit 1
  fi
  echo "ok $README_PATH test list is up to date"
  exit 0
fi
printf '%s' "$next" >"$ROOT/$README_PATH"
echo "ok wrote the test list in $README_PATH"
