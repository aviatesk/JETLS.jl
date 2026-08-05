#!/bin/bash

print_help() {
    cat <<'EOF'
Usage: ./scripts/update-release.sh [OPTIONS]

Update the current releases/YYYY-MM-DD branch from a source branch, regenerate
its vendored environment, and push the updated branch.

Options:
  -h, --help                    Show this help message and exit
  --no-push                     Update without pushing
  --remote REMOTE               Remote to fetch from (default: origin)
  --source-branch BRANCH        Source branch to merge (default: master)

Examples:
  ./scripts/update-release.sh
  ./scripts/update-release.sh --source-branch=master --remote=origin
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
        *)
            echo "Error: Unknown argument: $1"
            echo "Run with --help for usage information"
            exit 1
            ;;
    esac
done

ROOT_DIR=$(git rev-parse --show-toplevel)
cd "$ROOT_DIR"

CURRENT_BRANCH=$(git branch --show-current)
if [[ "$CURRENT_BRANCH" =~ ^releases/([0-9]{4}-[0-9]{2}-[0-9]{2})$ ]]; then
    JETLS_VERSION=${BASH_REMATCH[1]}
else
    echo "Error: Current branch must match releases/YYYY-MM-DD"
    echo "Current branch: ${CURRENT_BRANCH:-detached HEAD}"
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Error: You have uncommitted changes. Please commit or stash them first."
    exit 1
fi

if [[ ! -f JETLS_VERSION ]]; then
    echo "Error: JETLS_VERSION does not exist"
    exit 1
fi

RECORDED_VERSION=$(cat JETLS_VERSION)
if [[ "$RECORDED_VERSION" != "$JETLS_VERSION" ]]; then
    echo "Error: JETLS_VERSION does not match the current branch"
    echo "Branch version: $JETLS_VERSION"
    echo "Recorded version: $RECORDED_VERSION"
    exit 1
fi

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
    echo "Error: Git remote '$REMOTE' does not exist"
    exit 1
fi

echo "==> Updating release $JETLS_VERSION"
echo "==> Fetching $REMOTE/$SOURCE_BRANCH"
git fetch "$REMOTE" "$SOURCE_BRANCH"
SOURCE_COMMIT=$(git rev-parse FETCH_HEAD)
echo "Source commit: $SOURCE_COMMIT"

if ! git cat-file -e "$SOURCE_COMMIT:Project.toml" 2>/dev/null; then
    echo "Error: $REMOTE/$SOURCE_BRANCH does not contain Project.toml"
    exit 1
fi

echo "==> Step 1: Merging $REMOTE/$SOURCE_BRANCH"
git merge --no-ff "$SOURCE_COMMIT" -X theirs \
    -m "Merge $SOURCE_BRANCH into $CURRENT_BRANCH"

echo "==> Step 2: Vendoring dependencies with local sources"
julia --startup-file=no --project=. scripts/vendor-deps.jl \
    --source-branch="$SOURCE_COMMIT" --local

echo "==> Step 3: Committing vendored dependencies"
git add -A
if git diff --cached --quiet; then
    echo "Error: Vendoring did not produce any changes"
    exit 1
fi
git commit -m "vendor: update vendored dependencies"

VENDOR_COMMIT=$(git rev-parse HEAD)
echo "Vendor commit: $VENDOR_COMMIT"

echo "==> Step 4: Pinning vendored sources to the vendor commit"
julia --startup-file=no --project=. scripts/vendor-deps.jl \
    --source-branch="$SOURCE_COMMIT" --rev="$VENDOR_COMMIT"

echo "==> Step 5: Committing the updated release"
echo "$JETLS_VERSION" > JETLS_VERSION
TOML_VERSION=${JETLS_VERSION//-/.}
sed "s/^version = \".*\"/version = \"$TOML_VERSION\"/" Project.toml \
    > Project.toml.tmp
mv Project.toml.tmp Project.toml

git add -A
if git diff --cached --quiet; then
    echo "Error: Release metadata generation did not produce any changes"
    exit 1
fi
git commit -m "release: $JETLS_VERSION"

if [[ "$NO_PUSH" == true ]]; then
    echo ""
    echo "==> Release branch updated locally"
    echo "Branch: $CURRENT_BRANCH"
    echo "Source: $REMOTE/$SOURCE_BRANCH at $SOURCE_COMMIT"
    echo ""
    echo "Review the new commits and run the relevant release checks."
    echo "When ready, update the existing pull request with:"
    echo "  git push $REMOTE $CURRENT_BRANCH"
    exit 0
fi

echo "==> Step 6: Pushing the updated release branch"
git push "$REMOTE" "$CURRENT_BRANCH"

echo ""
echo "==> Existing release pull request updated"
echo "Branch: $CURRENT_BRANCH"
echo "Source: $REMOTE/$SOURCE_BRANCH at $SOURCE_COMMIT"
