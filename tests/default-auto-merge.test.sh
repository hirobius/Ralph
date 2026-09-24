#!/usr/bin/env bash
# RALPH_DEFAULT_AUTO_MERGE default (ralph#26).
#
# Per-repo opt-in defaulting to false is what keeps the blast radius honest:
# a caller must deliberately set the flag in its own ralph/config.env before
# a green AI-approved PR with no label at all can arm auto-merge. Sourcing
# the kit with nothing configured must yield false — never true, never unset.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

new_case default_is_false
unset RALPH_DEFAULT_AUTO_MERGE
VAL=$(cd "$CASE" && bash -c '. ralph/lib.sh; echo "$RALPH_DEFAULT_AUTO_MERGE"')
assert_eq false "$VAL" "RALPH_DEFAULT_AUTO_MERGE defaults to false with nothing configured"

new_case config_env_can_opt_in
unset RALPH_DEFAULT_AUTO_MERGE
echo 'RALPH_DEFAULT_AUTO_MERGE=true' >>"$CASE/ralph/config.env"
VAL=$(cd "$CASE" && bash -c '. ralph/lib.sh; echo "$RALPH_DEFAULT_AUTO_MERGE"')
assert_eq true "$VAL" "a caller's ralph/config.env can opt in explicitly"

report
