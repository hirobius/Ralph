#!/usr/bin/env bash
# Release-train check tests (ralph#45, spec #40): scripts/release.sh refuses a
# bad tag name, a taken tag, a dirty tree, a HEAD that is not origin/main and a
# red suite, and on success only PRINTS the tag and push commands.
#
# Each case builds a real throwaway repo with a bare "origin" (no network) and a
# copy of the script under scripts/, so nothing here touches the real repo. The
# real git is used on purpose; no case may ever leave a tag behind.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=tests/helpers.sh
. ./helpers.sh

RELEASE="$REPO_DIR/scripts/release.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

new_world() { # <name> — clone of a bare origin; main has one commit past v1
  CASE_NAME=$1
  W=$(mktemp -d "${TMPDIR:-/tmp}/ralph-rel-XXXXXX")
  git init -q --bare -b main "$W/origin.git"
  git clone -q "$W/origin.git" "$W/repo" 2>/dev/null
  mkdir -p "$W/repo/scripts" "$W/repo/tests"
  cp "$RELEASE" "$W/repo/scripts/release.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$W/repo/tests/run.sh"
  git -C "$W/repo" add -A
  git -C "$W/repo" commit -q -m "first"
  git -C "$W/repo" push -q origin HEAD:refs/heads/v1 2>/dev/null
  echo more >"$W/repo/more.txt"
  git -C "$W/repo" add -A
  git -C "$W/repo" commit -q -m "second change"
  git -C "$W/repo" push -q origin HEAD:main 2>/dev/null
  git -C "$W/repo" fetch -q origin
}

run() { # <args...>
  RUN_CODE=0
  RUN_OUT=$(cd "$W/repo" && bash scripts/release.sh "$@" 2>&1) || RUN_CODE=$?
}

no_tags() {
  assert_eq "" "$(git -C "$W/repo" tag)$(git -C "$W/origin.git" tag)" "no tag was created, locally or on origin"
}

refuses() { # <label> <needle> <args...>
  local label=$1 needle=$2
  shift 2
  run "$@"
  if [ "$RUN_CODE" -ne 0 ]; then _ok "$label: non-zero exit"; else _fail "$label: non-zero exit" "$RUN_OUT"; fi
  assert_contains "$RUN_OUT" "$needle" "$label: says why"
  case $RUN_OUT in *'git tag -a'*) _fail "$label: prints no commands" ;; *) _ok "$label: prints no commands" ;; esac
  no_tags
}

new_world refuse-v1
refuses "v1" "branch" v1 --skip-tests

new_world refuse-names
for bad in main v1.2 v2.0 1.2.3 v2-rc1 V2 v; do
  refuses "name $bad" "vN" "$bad" --skip-tests
done
run
if [ "$RUN_CODE" -ne 0 ]; then _ok "no tag argument is refused"; else _fail "no tag argument is refused"; fi

new_world refuse-local-tag
git -C "$W/repo" tag v2
run v2 --skip-tests
if [ "$RUN_CODE" -ne 0 ]; then _ok "existing local tag: non-zero exit"; else _fail "existing local tag: non-zero exit"; fi
assert_contains "$RUN_OUT" "exists locally" "existing local tag: says why"

new_world refuse-remote-tag
git -C "$W/origin.git" tag v2 "$(git -C "$W/origin.git" rev-parse main)"
run v2 --skip-tests
if [ "$RUN_CODE" -ne 0 ]; then _ok "tag on origin: non-zero exit"; else _fail "tag on origin: non-zero exit"; fi
assert_contains "$RUN_OUT" "exists on origin" "tag on origin: says why"
assert_eq "" "$(git -C "$W/repo" tag)" "tag on origin: no local tag created"

new_world refuse-dirty
echo x >>"$W/repo/more.txt"
refuses "dirty tracked file" "dirty" v2 --skip-tests
new_world refuse-untracked
echo x >"$W/repo/untracked.txt"
refuses "untracked file" "dirty" v2 --skip-tests

new_world refuse-not-main
git -C "$W/repo" checkout -q -b side HEAD~1
refuses "HEAD behind origin/main" "origin/main" v2 --skip-tests
new_world refuse-ahead
echo y >"$W/repo/y.txt"
git -C "$W/repo" add -A
git -C "$W/repo" commit -q -m "unpushed"
refuses "HEAD ahead of origin/main" "origin/main" v2 --skip-tests

new_world refuse-red
printf '#!/usr/bin/env bash\necho BOOM\nexit 1\n' >"$W/repo/tests/run.sh"
git -C "$W/repo" commit -q -am "red"
git -C "$W/repo" push -q origin HEAD:main 2>/dev/null
refuses "red tests" "tests" v2
run v2 --skip-tests
assert_eq 0 "$RUN_CODE" "--skip-tests passes a red suite"

new_world fetch-failure
git -C "$W/repo" remote set-url origin "$W/does-not-exist.git"
run v2 --skip-tests
if [ "$RUN_CODE" -ne 0 ]; then _ok "unreachable origin: still refuses to release"; else _fail "unreachable origin: still refuses to release"; fi

new_world happy-since-branch
sha=$(git -C "$W/repo" rev-parse HEAD)
run v2
assert_eq 0 "$RUN_CODE" "happy path exits 0"
assert_contains "$RUN_OUT" "second change" "lists commits since origin/v1"
case $RUN_OUT in *' first'*) _fail "does not list commits at or before origin/v1" ;; *) _ok "does not list commits at or before origin/v1" ;; esac
assert_contains "$RUN_OUT" "git tag -a v2 -m \"Ralph v2\" $sha" "prints the tag command with the sha"
assert_contains "$RUN_OUT" "git push origin refs/tags/v2" "prints the push command"
tail2=$(printf '%s\n' "$RUN_OUT" | tail -n 2)
assert_eq "git tag -a v2 -m \"Ralph v2\" $sha
git push origin refs/tags/v2" "$tail2" "the commands are exactly the last two lines"
no_tags
assert_eq "$sha" "$(git -C "$W/origin.git" rev-parse main)" "origin/main untouched"

new_world happy-semver-since-tag
git -C "$W/repo" tag -a v2 -m x HEAD
git -C "$W/repo" push -q origin refs/tags/v2 2>/dev/null
echo z >"$W/repo/z.txt"
git -C "$W/repo" add -A
git -C "$W/repo" commit -q -m "third change"
git -C "$W/repo" push -q origin HEAD:main 2>/dev/null
run v2.1.0 --skip-tests
assert_eq 0 "$RUN_CODE" "vN.M.P is accepted"
assert_contains "$RUN_OUT" "third change" "lists commits since the previous tag"
case $RUN_OUT in *'second change'*) _fail "stops at the previous tag" ;; *) _ok "stops at the previous tag" ;; esac
assert_contains "$RUN_OUT" "refs/tags/v2.1.0" "prints the push for the new tag"
assert_eq "v2" "$(git -C "$W/repo" tag)" "only the pre-existing tag is present"

report
