#!/bin/bash
# Run JETLS diagnostics on TestRunner source code
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
exec jetls check --root="$PROJECT_ROOT" --quiet --exit-severity=warn \
    "$PROJECT_ROOT/src/TestRunner.jl" "$@"
