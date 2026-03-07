#!/bin/bash
# Run JETLS self-diagnostics
#
# Usage: [JULIA=/path/to/julia] selfcheck.sh [OPTIONS]
#
# Environment variables:
#   JULIA=<path>          Julia executable (default: julia)
#
# Options are passed through to `jetls check`. Useful options include:
#   --skip-full-analysis  Skip the full analysis phase (faster, lowering-only)
#
# The following defaults can be overridden by passing them explicitly:
#   --threads=auto        Julia thread count
#   --root=<path>         Root path for configuration
#   --quiet / --no-quiet  Suppress/enable log messages
#   --exit-severity=warn  Minimum severity to exit with error
#   --show-severity=warn  Minimum severity to display
#
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Julia executable (override with JULIA environment variable)
JULIA="${JULIA:-julia}"

# Defaults
THREADS="auto"
ROOT="$PROJECT_ROOT"
QUIET="--quiet"
EXIT_SEVERITY="warn"
SHOW_SEVERITY="warn"
EXTRA_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            sed -n '2,/^[^#]/{ /^#/{ s/^# \{0,1\}//; p; }; }' "$0"
            exit 0
            ;;
        --threads=*)
            THREADS="${arg#--threads=}"
            ;;
        --root=*)
            ROOT="${arg#--root=}"
            ;;
        --quiet)
            QUIET="--quiet"
            ;;
        --no-quiet)
            QUIET=""
            ;;
        --exit-severity=*)
            EXIT_SEVERITY="${arg#--exit-severity=}"
            ;;
        --show-severity=*)
            SHOW_SEVERITY="${arg#--show-severity=}"
            ;;
        *)
            EXTRA_ARGS+=("$arg")
            ;;
    esac
done

exec "$JULIA" --startup-file=no --project="$PROJECT_ROOT" --threads="$THREADS" \
    -m JETLS check \
    --root="$ROOT" \
    $QUIET \
    --exit-severity="$EXIT_SEVERITY" \
    --show-severity="$SHOW_SEVERITY" \
    "$PROJECT_ROOT/src/JETLS.jl" "$PROJECT_ROOT/LSP/src/LSP.jl" \
    "${EXTRA_ARGS[@]}"
