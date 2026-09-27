#!/bin/bash
#
# Prepare a TestRunner release via pull request.
#
# Usage:
#     ./scripts/prepare-release.sh [--local]
#
# Options:
#     --local    Skip push and PR creation (for local testing)
#
# This script:
# 1. Creates a release-update branch from `release` and merges `master`
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
            echo "Usage: $0 [--local]"
            exit 1
            ;;
        *)
            echo "Error: Unexpected argument: $1"
            echo "Usage: $0 [--local]"
            exit 1
            ;;
    esac
done

BRANCH_NAME="release-update"

echo "==> Preparing release"

# Check for uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Error: You have uncommitted changes. Please commit or stash them first."
    exit 1
fi

# Check if release-update branch already exists
if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
    echo "Error: Branch $BRANCH_NAME already exists locally"
    echo "Delete it with: git branch -D $BRANCH_NAME"
    exit 1
fi

if git ls-remote --exit-code --heads origin "$BRANCH_NAME" >/dev/null 2>&1; then
    echo "Error: Branch $BRANCH_NAME already exists on remote"
    echo "Delete it with: git push origin --delete $BRANCH_NAME"
    exit 1
fi

# Step 1: Create release branch from `release` and merge `master`
echo "==> Step 1: Creating release branch and merging master"
git fetch origin release master
git checkout release
git pull origin release
git checkout -b "$BRANCH_NAME"
git merge origin/master -X theirs -m "Merge master into $BRANCH_NAME"

# Step 2: Vendor dependency packages with local paths
echo "==> Step 2: Vendoring dependencies (local paths)"
julia --startup-file=no --project=. scripts/vendor-deps.jl --source-branch=master --local

# Step 3: Commit vendor/ directory
echo "==> Step 3: Committing vendor/ directory"
# New packages under /vendor are ignored and need to be staged explicitly.
git add -f -A vendor/
git add -A
git commit -m "vendor: update vendored dependencies"
if [[ "$LOCAL_MODE" == true ]]; then
    echo ""
    echo "==> Local mode: stopping after vendor commit"
    echo ""
    echo "Branch $BRANCH_NAME has the vendor commit, but [sources] still"
    echo "references local paths instead of git revisions, so it is not"
    echo "suitable for a real release."
    echo ""
    echo "Clean up:"
    echo "  git checkout release && git branch -D $BRANCH_NAME"
    echo ""
    echo "To run a real release, drop the local branch and re-run without"
    echo "--local."
    exit 0
else
    git push -u origin "$BRANCH_NAME"
fi

# Step 4: Get the commit SHA and update [sources] to reference it
echo "==> Step 4: Updating [sources] to reference commit SHA"
VENDOR_COMMIT=$(git rev-parse HEAD)
echo "Vendor commit SHA: $VENDOR_COMMIT"
julia --startup-file=no --project=. scripts/vendor-deps.jl --source-branch=master --rev="$VENDOR_COMMIT"

# Step 5: Commit the final release
echo "==> Step 5: Committing release"
git add -A
git commit -m "release: update sources to reference vendor commit"

git push origin "$BRANCH_NAME"

# Step 6: Create pull request
echo "==> Step 6: Creating pull request"
PR_BODY="Update vendored dependencies.

## Checklist
- [ ] \`release / Test with vendored environment\`

## Post-merge
- The \`$BRANCH_NAME\` branch should be deleted after merging"

PR_URL=$(gh pr create \
    --base release \
    --head "$BRANCH_NAME" \
    --title "release: update vendored dependencies" \
    --body "$PR_BODY")

echo ""
echo "==> Release preparation complete!"
echo ""
echo "Pull request created: $PR_URL"
echo ""
echo "Next steps:"
echo "  1. Wait for CI to pass"
echo "  2. Merge the PR using 'Create a merge commit' (not squash or rebase)"
echo "  3. Delete the $BRANCH_NAME branch after merging"
