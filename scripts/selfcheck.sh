#!/bin/bash

print_help() {
    cat <<'EOF'
Usage: ./scripts/selfcheck.sh [OPTIONS]

Run JETLS self-diagnostics on the server and protocol source files. Unrecognized
options are passed through to jetls check.

Options:
  -h, --help              Show this help message and exit
  --threads=COUNT         Set the Julia thread count (default: auto)
  --root=PATH             Set the configuration root (default: project root)
  --quiet                 Suppress log messages (default)
  --no-quiet              Enable log messages
  --exit-severity=LEVEL   Set the failing severity (default: warn)
  --show-severity=LEVEL   Set the displayed severity (default: warn)
  --skip-full-analysis    Skip full analysis and only run lowering analysis

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
ROOT="$PROJECT_ROOT"
QUIET="--quiet"
EXIT_SEVERITY="warn"
SHOW_SEVERITY="warn"
EXTRA_ARGS=()

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            print_help
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
