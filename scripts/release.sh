#!/usr/bin/env bash
# Release-train preflight (ralph#45, ADR-009 section 2): checks that a tag can be
# cut and prints the exact commands. It NEVER runs `git tag` or `git push`; a
# person does, after reading what is about to ship.
#
# Usage: scripts/release.sh <tag> [--skip-tests]
#   <tag>  vN or vN.M.P (v1 is a branch and is released by fast-forward, see README)
set -uo pipefail

die() {
  echo "release: $*" >&2
  exit 1
}

tag=""
skip_tests=0
for a in "$@"; do
  case $a in
    --skip-tests) skip_tests=1 ;;
    -*) die "unknown option $a" ;;
    *)
      [ -z "$tag" ] || die "more than one tag given"
      tag=$a
      ;;
  esac
done
[ -n "$tag" ] || die "usage: scripts/release.sh <tag> [--skip-tests]"

[ "$tag" != v1 ] || die "v1 is a branch, not a tag; release it with the fast-forward push in the README"
if ! [[ $tag =~ ^v[0-9]+$ ]] && ! [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "tag '$tag' must look like vN or vN.M.P"
fi

cd "$(dirname "$0")/.." || die "cannot enter the repo root"

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  die "tag $tag exists locally"
fi
remote_tag=$(git ls-remote --tags origin "refs/tags/$tag" 2>/dev/null) || die "cannot read tags from origin"
[ -z "$remote_tag" ] || die "tag $tag exists on origin"

[ -z "$(git status --porcelain)" ] || die "working tree is dirty; commit or clean it first"

git fetch -q origin main 2>/dev/null || echo "release: warning: could not fetch origin main; using the last known origin/main" >&2
head_sha=$(git rev-parse HEAD)
main_sha=$(git rev-parse -q --verify refs/remotes/origin/main) || die "origin/main is unknown"
[ "$head_sha" = "$main_sha" ] || die "HEAD ($head_sha) is not origin/main ($main_sha); release from an up-to-date main"

if [ "$skip_tests" -eq 0 ]; then
  bash tests/run.sh >/dev/null 2>&1 || die "tests are red (bash tests/run.sh); fix them or pass --skip-tests"
fi

base=$(git tag --list 'v*' --sort=-v:refname --merged HEAD | head -n 1)
if [ -z "$base" ] && git rev-parse -q --verify refs/remotes/origin/v1 >/dev/null; then
  base=origin/v1
fi
if [ -n "$base" ]; then
  echo "Commits since $base:"
  git log --oneline "$base..HEAD"
else
  echo "Commits (no previous tag or origin/v1):"
  git log --oneline
fi
echo
echo "Checks passed for $tag. Run these yourself:"
echo "git tag -a $tag -m \"Ralph $tag\" $head_sha"
echo "git push origin refs/tags/$tag"
