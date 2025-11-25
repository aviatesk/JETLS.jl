#!/bin/bash
#
# Prepare a new JETLS release.
#
# Usage:
#     ./scripts/prepare-release.sh YYYY-MM-DD
#
# Example:
#     ./scripts/prepare-release.sh 2025-11-27
#
# This script automates the release procedure documented in DEVELOPMENT.md:
# 1. Creates a release branch from `release` and merges `master`
# 2. Vendors dependency packages
# 3. Commits and pushes
# 4. Creates a pull request to `release`

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 YYYY-MM-DD"
    echo "Example: $0 2025-11-27"
    exit 1
fi

JETLS_VERSION="$1"

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

# Step 2: Vendor dependency packages
echo "==> Step 2: Vendoring dependencies"
julia --startup-file=no --project=. scripts/vendor-deps.jl --source-branch=master

# Step 3: Commit and push
echo "==> Step 3: Committing and pushing"
git add -A
git commit -m "release: $JETLS_VERSION"
git push -u origin "releases/$JETLS_VERSION"

# Step 4: Create pull request
echo "==> Step 4: Creating pull request"
PR_URL=$(gh pr create \
    --base release \
    --head "releases/$JETLS_VERSION" \
    --title "release: $JETLS_VERSION" \
    --body "$(cat <<EOF
This PR releases version `$JETLS_VERSION`.

## Checklist
- [ ] `release / Test JETLS.jl with release environment`
- [ ] `release / Test jetls executable with release environment`

## Post-merge
- Do NOT delete the \`releases/$JETLS_VERSION\` branch after merging
- CHANGELOG.md will be automatically updated on master
EOF
)")

echo ""
echo "==> Release preparation complete!"
echo ""
echo "Pull request created: $PR_URL"
echo ""
echo "Next steps:"
echo "  1. Wait for CI to pass"
echo "  2. Merge the PR using 'Create a merge commit' (not squash or rebase)"
echo "  3. Do NOT delete the releases/$JETLS_VERSION branch"
