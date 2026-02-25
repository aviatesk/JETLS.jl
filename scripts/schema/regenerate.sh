#!/bin/bash
#
# Regenerate all schema files and update package.json.
#
# Usage:
#     ./scripts/schema/regenerate.sh [--check]
#
# Options:
#     --check    Verify that all generated files are up to date
#                instead of regenerating them.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CHECK_FLAG=""
if [[ "${1:-}" == "--check" ]]; then
    CHECK_FLAG="--check"
fi

julia --startup-file=no --project="$SCRIPT_DIR" \
    "$SCRIPT_DIR/generate.jl" --config-toml "$PROJECT_ROOT/schemas/config-toml.schema.json" $CHECK_FLAG
julia --startup-file=no --project="$SCRIPT_DIR" \
    "$SCRIPT_DIR/generate.jl" --settings "$PROJECT_ROOT/schemas/settings.schema.json" $CHECK_FLAG
julia --startup-file=no --project="$SCRIPT_DIR" \
    "$SCRIPT_DIR/generate.jl" --init-options "$PROJECT_ROOT/schemas/init-options.schema.json" $CHECK_FLAG
julia --startup-file=no --project="$SCRIPT_DIR" \
    "$SCRIPT_DIR/update-pkg-json.jl" "$PROJECT_ROOT/jetls-client/package.json" $CHECK_FLAG
