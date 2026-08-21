#!/usr/bin/env bash
# Cut a version tag. Semantic versioning lives in git tags and nowhere else —
# there is no VERSION file to forget to update, and no number duplicated in a
# project.godot that can drift from the tag.
#
#   tools/release.sh patch          0.1.0 -> 0.1.1   a fix, nothing new
#   tools/release.sh minor          0.1.0 -> 0.2.0   new behaviour, still compatible
#   tools/release.sh major          0.1.0 -> 1.0.0   something people relied on changed
#   tools/release.sh 1.4.2          exactly that
#   tools/release.sh minor --push   and push the tag
#
# The tree must be clean. A release has to be reproducible from its tag, and a
# tag pointing at a commit plus "some uncommitted stuff" is not.
set -euo pipefail
cd "$(dirname "$0")/.."

BUMP="${1:-}"
PUSH=0
[[ "${2:-}" == "--push" ]] && PUSH=1

if [[ -z "$BUMP" ]]; then
    echo "usage: $(basename "$0") patch|minor|major|X.Y.Z [--push]" >&2
    echo "" >&2
    echo "current: $(tools/version.sh)" >&2
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: the working tree is not clean." >&2
    echo "       A release must be reproducible from its tag; commit or stash first." >&2
    git status --short >&2
    exit 1
fi

# Latest vX.Y.Z, or nothing yet.
LATEST="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)"
CURRENT="${LATEST#v}"
CURRENT="${CURRENT:-0.0.0}"
IFS=. read -r MA MI PA <<< "$CURRENT"

case "$BUMP" in
    major) NEXT="$((MA + 1)).0.0" ;;
    minor) NEXT="${MA}.$((MI + 1)).0" ;;
    patch) NEXT="${MA}.${MI}.$((PA + 1))" ;;
    [0-9]*.[0-9]*.[0-9]*) NEXT="$BUMP" ;;
    *) echo "error: '$BUMP' is not patch, minor, major or an X.Y.Z version" >&2; exit 1 ;;
esac

if git rev-parse "v$NEXT" >/dev/null 2>&1; then
    echo "error: v$NEXT already exists." >&2
    exit 1
fi

# What changed since the last release, as the tag's message.
if [[ -n "$LATEST" ]]; then
    RANGE="$LATEST..HEAD"
    COUNT="$(git rev-list --count "$RANGE")"
else
    RANGE=""
    COUNT="$(git rev-list --count HEAD)"
fi
if [[ "$COUNT" == "0" ]]; then
    echo "error: nothing new since $LATEST — there is no release to cut." >&2
    exit 1
fi

echo "  $CURRENT -> $NEXT   ($COUNT commit(s))"
{
    echo "qGames $NEXT"
    echo ""
    if [[ -n "$RANGE" ]]; then git log --format='- %s' "$RANGE"; else git log --format='- %s' -20; fi
} | git tag -a "v$NEXT" -F -

echo "tagged v$NEXT"
echo "  version is now: $(tools/version.sh)"

if [[ $PUSH -eq 1 ]]; then
    git push origin "v$NEXT"
    echo "  pushed"
else
    echo "  not pushed — 'git push origin v$NEXT' when ready"
fi
echo ""
echo "Rebuild so the artefacts carry it:  make dist"
