#!/bin/bash
#
# Prepare a new JETLS release.
#
# Usage:
#     ./scripts/prepare-release.sh YYYY-MM-DD [--local]
#
# Example:
#     ./scripts/prepare-release.sh 2025-11-27
#     ./scripts/prepare-release.sh 2025-11-27 --local  # skip push and PR creation
#
# This script automates the release procedure documented in DEVELOPMENT.md:
# 1. Creates a release branch from `release` and merges `master`
# 2. Vendors dependency packages
# 3. Commits and pushes
# 4. Creates a pull request to `release`

set -euo pipefail

LOCAL_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --local)
            LOCAL_MODE=true
            shift
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Usage: $0 YYYY-MM-DD [--local]"
            exit 1
            ;;
        *)
            if [[ -z "${JETLS_VERSION:-}" ]]; then
                JETLS_VERSION="$1"
            else
                echo "Error: Unexpected argument: $1"
                echo "Usage: $0 YYYY-MM-DD [--local]"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "${JETLS_VERSION:-}" ]]; then
    echo "Usage: $0 YYYY-MM-DD [--local]"
    echo "Example: $0 2025-11-27"
    exit 1
fi

# Validate date format
if ! [[ "$JETLS_VERSION" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "Error: Version must be in YYYY-MM-DD format"
    exit 1
fi

echo "==> Preparing release $JETLS_VERSION"

# Check for uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Error: You have uncommitted changes. Please commit or stash them first."
    exit 1
fi

# Check if release branch already exists
if git show-ref --verify --quiet "refs/heads/releases/$JETLS_VERSION"; then
    echo "Error: Branch releases/$JETLS_VERSION already exists locally"
    exit 1
fi

if git ls-remote --exit-code --heads origin "releases/$JETLS_VERSION" >/dev/null 2>&1; then
    echo "Error: Branch releases/$JETLS_VERSION already exists on remote"
    exit 1
fi

# Step 1: Create release branch from `release` and merge `master`
echo "==> Step 1: Creating release branch and merging master"
git fetch origin release master
git checkout release
git pull origin release
git checkout -b "releases/$JETLS_VERSION"
git merge origin/master -X theirs -m "Merge master into releases/$JETLS_VERSION"

# Step 2: Vendor dependency packages with local paths
echo "==> Step 2: Vendoring dependencies (local paths)"
julia --startup-file=no --project=. scripts/vendor-deps.jl --source-branch=master --local

# Step 3: Commit vendor/ directory
echo "==> Step 3: Committing vendor/ directory"
git add -A
git commit -m "vendor: update vendored dependencies"
if [[ "$LOCAL_MODE" == false ]]; then
    git push -u origin "releases/$JETLS_VERSION"
fi

# Step 4: Get the commit SHA and update [sources] to reference it
echo "==> Step 4: Updating [sources] to reference commit SHA"
VENDOR_COMMIT=$(git rev-parse HEAD)
echo "Vendor commit SHA: $VENDOR_COMMIT"
julia --startup-file=no --project=. scripts/vendor-deps.jl --source-branch=master --rev="$VENDOR_COMMIT"

# Step 5: Commit the final release
echo "==> Step 5: Committing release"
echo "$JETLS_VERSION" > JETLS_VERSION
git add -A
git commit -m "release: $JETLS_VERSION"

if [[ "$LOCAL_MODE" == true ]]; then
    echo ""
    echo "==> Local mode: skipping push and PR creation"
    echo ""
    echo "Release branch prepared locally: releases/$JETLS_VERSION"
    echo "To complete the release manually:"
    echo "  1. git push -u origin releases/$JETLS_VERSION"
    echo "  2. Create a PR from releases/$JETLS_VERSION to release"
    exit 0
fi

git push origin "releases/$JETLS_VERSION"

# Step 6: Create pull request
echo "==> Step 6: Creating pull request"
PR_BODY="This PR releases version \`$JETLS_VERSION\`.

## Checklist
- [ ] \`release / Test JETLS.jl with release environment\`
- [ ] \`release / Test jetls serve with release environment\`
- [ ] \`release / Test jetls check with release environment\`

## Post-merge
- The \`releases/$JETLS_VERSION\` branch can be deleted after merging
- CHANGELOG.md will be automatically updated on master"

PR_URL=$(gh pr create \
    --base release \
    --head "releases/$JETLS_VERSION" \
    --title "release: $JETLS_VERSION" \
    --body "$PR_BODY")

echo ""
echo "==> Release preparation complete!"
echo ""
echo "Pull request created: $PR_URL"
echo ""
echo "Next steps:"
echo "  1. Wait for CI to pass"
echo "  2. Merge the PR using 'Create a merge commit' (not squash or rebase)"
echo "  3. The releases/$JETLS_VERSION branch can be deleted after merging"
