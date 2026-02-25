#!/bin/bash
#
# Regenerate all schema files and update package.json.
#
# Usage:
#     ./scripts/schema/regenerate.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

julia --startup-file=no --project="$SCRIPT_DIR" \
    "$SCRIPT_DIR/generate.jl" --config-toml "$PROJECT_ROOT/schemas/config-toml.schema.json"
julia --startup-file=no --project="$SCRIPT_DIR" \
    "$SCRIPT_DIR/generate.jl" --settings "$PROJECT_ROOT/schemas/settings.schema.json"
julia --startup-file=no --project="$SCRIPT_DIR" \
    "$SCRIPT_DIR/generate.jl" --init-options "$PROJECT_ROOT/schemas/init-options.schema.json"
julia --startup-file=no --project="$SCRIPT_DIR" \
    "$SCRIPT_DIR/update-pkg-json.jl" "$PROJECT_ROOT/jetls-client/package.json"
