#!/bin/bash
# Run JETLS self-diagnostics
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
exec julia --startup-file=no --project="$PROJECT_ROOT" --threads=auto -m JETLS check --root="$PROJECT_ROOT" --quiet "$PROJECT_ROOT/src/JETLS.jl" "$PROJECT_ROOT/LSP/src/LSP.jl" --exit-severity=warn --show-severity=warn "$@"
