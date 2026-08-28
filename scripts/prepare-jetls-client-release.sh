#!/bin/bash

print_help() {
    cat <<'EOF'
Usage: ./scripts/prepare-jetls-client-release.sh [OPTIONS] VERSION

Prepare a jetls-client release branch, create the release commit, and open
a pull request against master. Merging the pull request triggers the
publish workflow (.github/workflows/jetls-client-release.yml), which
packages the extension, publishes it to the Marketplace, and pushes the
`jetls-client/vVERSION` tag.

Arguments:
  VERSION       Release version in YYYY.M.D format without zero padding
                (e.g. 2026.8.23), normally today's date

Options:
  -h, --help        Show this help message and exit
  --no-push         Prepare without pushing or opening a PR
  --pin REVISION    Update the pinned JETLS release in
                    jetls-client/JETLS_VERSION.json to REVISION
                    (YYYY-MM-DD) before releasing
  --remote REMOTE   Remote to use (default: origin)

Examples:
  ./scripts/prepare-jetls-client-release.sh --no-push 2026.8.23
  ./scripts/prepare-jetls-client-release.sh --pin 2026-08-23 2026.8.23
EOF
}

set -euo pipefail

NO_PUSH=false
REMOTE=origin
PIN=
VERSION=

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            print_help
            exit 0
            ;;
        --no-push)
            NO_PUSH=true
            shift
            ;;
        --pin)
            if [[ $# -lt 2 ]]; then
                echo "Error: --pin requires a value"
                exit 1
            fi
            PIN=$2
            shift 2
            ;;
        --pin=*)
            PIN=${1#*=}
            shift
            ;;
        --remote)
            if [[ $# -lt 2 ]]; then
                echo "Error: --remote requires a value"
                exit 1
            fi
            REMOTE=$2
            shift 2
            ;;
        --remote=*)
            REMOTE=${1#*=}
            shift
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Usage: $0 [OPTIONS] VERSION"
            exit 1
            ;;
        *)
            if [[ -z "$VERSION" ]]; then
                VERSION=$1
            else
                echo "Error: Unexpected argument: $1"
                echo "Usage: $0 [OPTIONS] VERSION"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 [OPTIONS] VERSION"
    echo "Example: $0 2026.8.23"
    exit 1
fi

# The Marketplace requires semver, which rejects zero-padded numerals.
if [[ ! "$VERSION" =~ ^20[0-9]{2}\.(1[0-2]|[1-9])\.(3[01]|[12][0-9]|[1-9])$ ]]; then
    echo "Error: VERSION must be YYYY.M.D without zero padding (e.g. 2026.8.23)"
    exit 1
fi

TAG="jetls-client/v$VERSION"
BRANCH="jetls-client-releases/v$VERSION"

echo "==> Preparing jetls-client release v$VERSION"

cd "$(dirname "$0")/.."

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
    echo "Error: Git remote '$REMOTE' does not exist"
    exit 1
fi

# Check for uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Error: You have uncommitted changes. Please commit or stash them first."
    exit 1
fi

# Check if the release branch or tag already exists
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    echo "Error: Branch $BRANCH already exists locally"
    exit 1
fi
if git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
    echo "Error: Branch $BRANCH already exists on remote"
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "Error: Tag $TAG already exists locally"
    exit 1
fi
if git ls-remote --exit-code --tags "$REMOTE" "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "Error: Tag $TAG already exists on remote"
    exit 1
fi

echo "==> Step 1: Creating release branch from $REMOTE/master"
git fetch "$REMOTE" master
git checkout -b "$BRANCH" "$REMOTE/master"

MANIFEST=jetls-client/JETLS_VERSION.json
if [[ -n "$PIN" ]]; then
    if [[ ! "$PIN" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "Error: --pin must be a YYYY-MM-DD release tag (e.g. 2026-08-23)"
        exit 1
    fi
    sed -i.bak -E "s/\"revision\": \"[^\"]*\"/\"revision\": \"$PIN\"/" "$MANIFEST"
    rm "$MANIFEST.bak"
    echo "Updated pinned JETLS release to $PIN"
fi

REVISION=$(node -p "require('./$MANIFEST').revision")
echo "==> Step 2: Validating pinned JETLS release $REVISION"
if ! git ls-remote --exit-code --tags "$REMOTE" "refs/tags/$REVISION" >/dev/null; then
    echo "Error: pinned JETLS release tag $REVISION not found on $REMOTE."
    exit 1
fi
git fetch --quiet --no-tags "$REMOTE" "refs/tags/$REVISION"
scripts/check-jetls-client-julia-bounds.sh FETCH_HEAD

echo "==> Step 3: Setting extension version to $VERSION"
(cd jetls-client && npm version "$VERSION" --no-git-tag-version >/dev/null)

echo "==> Step 4: Finalizing the CHANGELOG"
CHANGELOG=jetls-client/CHANGELOG.md
if ! grep -Fxq "## Unreleased" "$CHANGELOG"; then
    echo "Error: no '## Unreleased' section in $CHANGELOG."
    exit 1
fi
# GitHub's `/commit/<ref>` endpoint 404s on refs containing slashes, so the
# Commit link points at `/tree/<tag>` instead. The Pinned line makes the
# paired server release explicit, since the extension version only records
# the client release date.
PINNED_LINE="- Pinned JETLS: [\`$REVISION\`](https://github.com/aviatesk/JETLS.jl/releases/tag/$REVISION)"
sed -i.bak -E \
    -e "s|^## Unreleased$|## v$VERSION|" \
    -e "/^- (Commit|Diff): /s|HEAD|$TAG|g" \
    -e "s|/commit/$TAG|/tree/$TAG|" \
    -e "s|^(- Diff: .*$TAG\))$|\1\\
$PINNED_LINE|" \
    "$CHANGELOG"
rm "$CHANGELOG.bak"
# Re-create an empty Unreleased section above the released one, so future
# entries have a place to land and pin-only automated releases (which add
# no entries of their own) keep working.
awk -v ver="## v$VERSION" -v tag="$TAG" '
    $0 == ver && !done {
        print "## Unreleased"
        print ""
        print "- Commit: [`HEAD`](https://github.com/aviatesk/JETLS.jl/commit/HEAD)"
        print "- Diff: [`" tag "...HEAD`](https://github.com/aviatesk/JETLS.jl/compare/" tag "...HEAD)"
        print ""
        done = 1
    }
    { print }
' "$CHANGELOG" > "$CHANGELOG.tmp" && mv "$CHANGELOG.tmp" "$CHANGELOG"
released_section() {
    awk -v ver="## v$VERSION" '
        /^## / { if (found) exit; if ($0 == ver) { found = 1; next } }
        found' "$CHANGELOG"
}
if ! grep -Fxq "## Unreleased" "$CHANGELOG" ||
    ! grep -Fxq "## v$VERSION" "$CHANGELOG" ||
    ! released_section | grep -Fq -- "$PINNED_LINE" ||
    released_section | grep -q "HEAD"; then
    echo "Error: failed to finalize the Unreleased section in $CHANGELOG."
    exit 1
fi

echo "==> Step 5: Committing the release"
git add jetls-client/package.json jetls-client/package-lock.json \
    "$CHANGELOG" "$MANIFEST"
git commit -m "jetls-client: v$VERSION"

if [[ "$NO_PUSH" == true ]]; then
    echo ""
    echo "==> Skipping push and PR creation"
    echo ""
    echo "Release branch prepared locally: $BRANCH"
    echo "To complete the release manually:"
    echo "  1. git push -u $REMOTE $BRANCH"
    echo "  2. Create a PR from $BRANCH to master"
    exit 0
fi

git push -u "$REMOTE" "$BRANCH"

echo "==> Step 6: Creating pull request"
PR_BODY="This PR releases jetls-client \`v$VERSION\`, pinning the JETLS release \`$REVISION\`.

Merging this PR publishes the extension to the Marketplace and pushes the \`$TAG\` tag."

PR_URL=$(gh pr create \
    --base master \
    --head "$BRANCH" \
    --title "jetls-client: v$VERSION" \
    --body "$PR_BODY")

echo ""
echo "==> Release preparation complete!"
echo ""
echo "Pull request created: $PR_URL"
echo ""
echo "Next steps:"
echo "  1. Wait for CI to pass"
echo "  2. Merge the PR to publish the release"
echo "  3. The $BRANCH branch can be deleted after merging"
