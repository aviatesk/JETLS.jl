#!/bin/bash

print_help() {
    cat <<'EOF'
Usage: ./scripts/schema/regenerate.sh [OPTIONS]

Regenerate all JETLS configuration schemas and update package.json.

Options:
  -h, --help    Show this help message and exit
  --check       Verify that all generated files are up to date
EOF
}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CHECK_FLAG=""
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            print_help
            exit 0
            ;;
        --check)
            CHECK_FLAG="--check"
            ;;
        *)
            ;;
    esac
done

julia --startup-file=no --project="$SCRIPT_DIR" \
    "$SCRIPT_DIR/generate.jl" --config-toml "$PROJECT_ROOT/schemas/config-toml.schema.json" $CHECK_FLAG
julia --startup-file=no --project="$SCRIPT_DIR" \
    "$SCRIPT_DIR/generate.jl" --settings "$PROJECT_ROOT/schemas/settings.schema.json" $CHECK_FLAG
julia --startup-file=no --project="$SCRIPT_DIR" \
    "$SCRIPT_DIR/generate.jl" --init-options "$PROJECT_ROOT/schemas/init-options.schema.json" $CHECK_FLAG
julia --startup-file=no --project="$SCRIPT_DIR" \
    "$SCRIPT_DIR/generate.jl" --vscode-configuration "$PROJECT_ROOT/schemas/vscode-configuration.json" $CHECK_FLAG
julia --startup-file=no --project="$SCRIPT_DIR" \
    "$SCRIPT_DIR/update-pkg-json.jl" "$PROJECT_ROOT/jetls-client/package.json" $CHECK_FLAG
