#!/bin/bash

PROJECTS=(JETLS JETLSCore HierarchicalTestSets LSP MarkdownSource TOMLSource TestRunner docs scripts)

print_help() {
    cat <<EOF
Usage: ./scripts/selfcheck.sh [OPTIONS]

Run JETLS self-diagnostics on the projects of this repository, or only on
those given by -p: the packages along with their test suites, and the Julia
files in docs and scripts. Other options are passed through to jetls check
and override the defaults --root=<project root> and --show-severity=warn.

Projects:
  ${PROJECTS[*]}

Options:
  -h, --help              Show this help message and exit
  -p, --project NAME      Check only the project NAME; may be repeated
  --threads=COUNT         Set the Julia thread count (default: auto)
  --no-quiet              Enable log messages (suppressed by default)

Environment variables:
  JULIA=PATH              Set the Julia executable (default: julia)
EOF
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Julia executable (override with JULIA environment variable)
JULIA="${JULIA:-julia}"

# Defaults
THREADS="auto"
QUIET="--quiet"
PROJECT_NAMES=()
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
        -p|--project)
            if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires a value" >&2
                exit 1
            fi
            PROJECT_NAMES+=("$2")
            shift
            ;;
        --project=*)
            PROJECT_NAMES+=("${1#--project=}")
            ;;
        --threads=*)
            THREADS="${1#--threads=}"
            ;;
        --no-quiet)
            QUIET=""
            ;;
        *)
            EXTRA_ARGS+=("$1")
            ;;
    esac
    shift
done

is_project() {
    local name
    for name in "${PROJECTS[@]}"; do
        if [[ "$name" == "$1" ]]; then
            return 0
        fi
    done
    return 1
}

if [[ ${#PROJECT_NAMES[@]} -eq 0 ]]; then
    PROJECT_NAMES=("${PROJECTS[@]}")
fi
PACKAGE_PATHS=()
FILE_PATHS=()
for name in "${PROJECT_NAMES[@]}"; do
    if ! is_project "$name"; then
        echo "Error: Unknown project: $name (expected one of: ${PROJECTS[*]})" >&2
        exit 1
    fi
    if [[ "$name" == JETLS ]]; then
        PACKAGE_PATHS+=("$PROJECT_ROOT")
        FILE_PATHS+=("$PROJECT_ROOT/test/runtests.jl")
    elif [[ "$name" == JETLSCore ]]; then
        PACKAGE_PATHS+=("$PROJECT_ROOT/$name")
    elif [[ "$name" == docs || "$name" == scripts ]]; then
        FILE_PATHS+=("$PROJECT_ROOT/$name"/*.jl)
    else
        PACKAGE_PATHS+=("$PROJECT_ROOT/$name")
        FILE_PATHS+=("$PROJECT_ROOT/$name/test/runtests.jl")
    fi
done

exec "$JULIA" --startup-file=no --project="$PROJECT_ROOT" --threads="$THREADS" \
    -m JETLS check \
    --root="$PROJECT_ROOT" \
    $QUIET \
    --show-severity=warn \
    "${PACKAGE_PATHS[@]}" \
    "${FILE_PATHS[@]}" \
    "${EXTRA_ARGS[@]}"
