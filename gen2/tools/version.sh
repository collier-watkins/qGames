#!/usr/bin/env bash
# Print the version of the current tree, derived from git tags.
#
# Scheme (semver 2.0.0):
#   exactly on tag v1.2.3          -> 1.2.3
#   4 commits past it              -> 1.2.3+4.gab12cd
#   with uncommitted changes       -> 1.2.3+4.gab12cd.dirty
#   no tags in the repository yet  -> 0.0.0+gab12cd
#
# Everything after "+" is semver BUILD METADATA, which is explicitly ignored
# when comparing versions. That is the honest encoding: a build four commits
# past v1.2.3 is not v1.2.4 — nobody has decided what the next version is —
# but it must still be told apart from the tagged release, because it is a
# different artifact.
#
# To cut a release:  git tag -a v0.1.0 -m "..."   (annotated; lightweight works too)
set -euo pipefail
cd "$(dirname "$0")/.."

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "0.0.0+nogit"
    exit 0
fi

sha="$(git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
dirty=""
# --porcelain covers staged, unstaged and untracked; an untracked file changes
# what an export contains, so it counts.
[[ -n "$(git status --porcelain 2>/dev/null)" ]] && dirty=".dirty"

# Only vX.Y.Z tags count. A stray tag like "backup" must not become a version.
if described="$(git describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --long 2>/dev/null)"; then
    tag="${described%-*-g*}"          # v1.2.3
    rest="${described#"$tag"-}"       # 4-gab12cd
    ahead="${rest%%-*}"               # 4
    base="${tag#v}"                   # 1.2.3
    if [[ "$ahead" == "0" && -z "$dirty" ]]; then
        echo "$base"
    else
        echo "$base+${ahead}.g${sha}${dirty}"
    fi
else
    echo "0.0.0+g${sha}${dirty}"
fi
