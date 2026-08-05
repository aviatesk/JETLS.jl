#!/bin/bash

print_help() {
    cat <<'EOF'
Usage: ./scripts/prepare-release.sh [OPTIONS] VERSION

Prepare a JETLS release branch, vendor dependencies, create commits, and open a
pull request against the release branch.

Arguments:
  VERSION       Release version in YYYY-MM-DD format

Options:
  -h, --help                    Show this help message and exit
  --no-push                     Prepare without pushing or opening a PR
  --remote REMOTE               Remote to use (default: origin)
  --source-branch BRANCH        Source branch to merge (default: master)

Examples:
  ./scripts/prepare-release.sh --no-push 2026-08-01
  ./scripts/prepare-release.sh --source-branch=master 2026-08-01
EOF
}

set -euo pipefail

NO_PUSH=false
REMOTE=origin
SOURCE_BRANCH=master

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
        --source-branch)
            if [[ $# -lt 2 ]]; then
                echo "Error: --source-branch requires a value"
                exit 1
            fi
            SOURCE_BRANCH=$2
            shift 2
            ;;
        --source-branch=*)
            SOURCE_BRANCH=${1#*=}
            shift
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Usage: $0 [OPTIONS] VERSION"
            exit 1
            ;;
        *)
            if [[ -z "${JETLS_VERSION:-}" ]]; then
                JETLS_VERSION="$1"
            else
                echo "Error: Unexpected argument: $1"
                echo "Usage: $0 [OPTIONS] VERSION"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "${JETLS_VERSION:-}" ]]; then
    echo "Usage: $0 [OPTIONS] VERSION"
    echo "Example: $0 2025-11-27"
    exit 1
fi

# Validate date format
if ! [[ "$JETLS_VERSION" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "Error: Version must be in YYYY-MM-DD format"
    exit 1
fi

echo "==> Preparing release $JETLS_VERSION"

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
    echo "Error: Git remote '$REMOTE' does not exist"
    exit 1
fi

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

if git ls-remote --exit-code --heads "$REMOTE" "releases/$JETLS_VERSION" >/dev/null 2>&1; then
    echo "Error: Branch releases/$JETLS_VERSION already exists on remote"
    exit 1
fi

# Step 1: Create release branch from `release` and merge the source branch
echo "==> Step 1: Creating release branch and merging $REMOTE/$SOURCE_BRANCH"
git fetch "$REMOTE" release "$SOURCE_BRANCH"
SOURCE_COMMIT=$(git rev-parse "$REMOTE/$SOURCE_BRANCH")
echo "Source commit SHA: $SOURCE_COMMIT"
git checkout release
git pull "$REMOTE" release
git checkout -b "releases/$JETLS_VERSION"
git merge "$SOURCE_COMMIT" -X theirs -m "Merge $SOURCE_BRANCH into releases/$JETLS_VERSION"

# Step 2: Vendor dependency packages with local paths
echo "==> Step 2: Vendoring dependencies (local paths)"
julia --startup-file=no --project=. scripts/vendor-deps.jl --source-branch="$SOURCE_COMMIT" --local

# Step 3: Commit vendor/ directory
echo "==> Step 3: Committing vendor/ directory"
git add -A
git commit -m "vendor: update vendored dependencies"
if [[ "$NO_PUSH" == false ]]; then
    git push -u "$REMOTE" "releases/$JETLS_VERSION"
fi

# Step 4: Get the commit SHA and update [sources] to reference it
echo "==> Step 4: Updating [sources] to reference commit SHA"
VENDOR_COMMIT=$(git rev-parse HEAD)
echo "Vendor commit SHA: $VENDOR_COMMIT"
julia --startup-file=no --project=. scripts/vendor-deps.jl --source-branch="$SOURCE_COMMIT" --rev="$VENDOR_COMMIT"

# Step 5: Commit the final release
echo "==> Step 5: Committing release"
echo "$JETLS_VERSION" > JETLS_VERSION
# Update Project.toml version (convert YYYY-MM-DD to YYYY.MM.DD for Julia VersionNumber)
TOML_VERSION="${JETLS_VERSION//-/.}"
sed "s/^version = \".*\"/version = \"$TOML_VERSION\"/" Project.toml > Project.toml.tmp && mv Project.toml.tmp Project.toml
git add -A
git commit -m "release: $JETLS_VERSION"

if [[ "$NO_PUSH" == true ]]; then
    echo ""
    echo "==> Skipping push and PR creation"
    echo ""
    echo "Release branch prepared locally: releases/$JETLS_VERSION"
    echo "To complete the release manually:"
    echo "  1. git push -u $REMOTE releases/$JETLS_VERSION"
    echo "  2. Create a PR from releases/$JETLS_VERSION to release"
    exit 0
fi

git push "$REMOTE" "releases/$JETLS_VERSION"

# Step 6: Create pull request
echo "==> Step 6: Creating pull request"
PR_BODY="This PR releases version \`$JETLS_VERSION\`."

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
