#!/usr/bin/env bash
# Checks that the julia bounds in jetls-client/JETLS_VERSION.json mirror
# the pinned JETLS release's `julia` compat entry, which is required to
# stay in the `<lower> - <upper>` hyphen-range form this comparison
# assumes; drift in either direction fails the check.
#
# Usage: check-jetls-client-julia-bounds.sh [<committish>]
#
# The pinned release's Project.toml is read from <committish> when given
# (e.g. FETCH_HEAD after fetching the pinned tag), and otherwise through
# the GitHub contents API via `gh api`, which works from a shallow
# checkout without the tag fetched.
set -euo pipefail

cd "$(dirname "$0")/.."

MANIFEST=jetls-client/JETLS_VERSION.json
REVISION=$(node -p "require('./$MANIFEST').revision")
JULIA_LOWER=$(node -p "require('./$MANIFEST').julia.lower")
JULIA_UPPER=$(node -p "require('./$MANIFEST').julia.upper")

if [[ $# -ge 1 ]]; then
    PROJECT_TOML=$(git show "$1:Project.toml")
else
    REPOSITORY=${GITHUB_REPOSITORY:-aviatesk/JETLS.jl}
    PROJECT_TOML=$(gh api "repos/$REPOSITORY/contents/Project.toml?ref=$REVISION" \
        --jq .content | base64 -d)
fi

COMPAT=$(printf '%s\n' "$PROJECT_TOML" |
    sed -n '/^\[compat\]/,/^\[/p' | sed -n 's/^julia = "\(.*\)"$/\1/p')
if [[ -z "$COMPAT" ]]; then
    echo "Error: could not read the julia compat entry of the pinned release $REVISION."
    exit 1
fi
if [[ "$COMPAT" != "$JULIA_LOWER - $JULIA_UPPER" ]]; then
    echo "Error: julia bounds in $MANIFEST ($JULIA_LOWER - $JULIA_UPPER)" \
        "do not match the pinned release's julia compat ($COMPAT)."
    exit 1
fi
echo "julia bounds in $MANIFEST match the pinned release $REVISION ($COMPAT)."
