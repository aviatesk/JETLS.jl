#!/bin/bash

PACKAGES=(JETLS HierarchicalTestSets LSP TOMLSource)

print_help() {
    cat <<EOF
Usage: ./scripts/selfcheck.sh [OPTIONS]

Run JETLS self-diagnostics on the packages of this repository, or only on
those given by -p. Other options are passed through to jetls check and
override the defaults --root=<project root> and --show-severity=warn.

Packages:
  ${PACKAGES[*]}

Options:
  -h, --help              Show this help message and exit
  -p, --package NAME      Check only the package NAME; may be repeated
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
PACKAGE_NAMES=()
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
        -p|--package)
            if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires a value" >&2
                exit 1
            fi
            PACKAGE_NAMES+=("$2")
            shift
            ;;
        --package=*)
            PACKAGE_NAMES+=("${1#--package=}")
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

is_package() {
    local name
    for name in "${PACKAGES[@]}"; do
        if [[ "$name" == "$1" ]]; then
            return 0
        fi
    done
    return 1
}

if [[ ${#PACKAGE_NAMES[@]} -eq 0 ]]; then
    PACKAGE_NAMES=("${PACKAGES[@]}")
fi
PACKAGE_PATHS=()
for name in "${PACKAGE_NAMES[@]}"; do
    if ! is_package "$name"; then
        echo "Error: Unknown package: $name (expected one of: ${PACKAGES[*]})" >&2
        exit 1
    fi
    if [[ "$name" == JETLS ]]; then
        PACKAGE_PATHS+=("$PROJECT_ROOT")
    else
        PACKAGE_PATHS+=("$PROJECT_ROOT/$name")
    fi
done

exec "$JULIA" --startup-file=no --project="$PROJECT_ROOT" --threads="$THREADS" \
    -m JETLS check \
    --root="$PROJECT_ROOT" \
    $QUIET \
    --show-severity=warn \
    "${PACKAGE_PATHS[@]}" \
    "${EXTRA_ARGS[@]}"
