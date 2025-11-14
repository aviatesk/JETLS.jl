# Diagnostics

JETLS reports various diagnostic messages (errors, warnings, hints) to help you
catch potential issues in your Julia code. Each diagnostic has a unique code
that identifies its category and type.

This document describes all available diagnostic codes, their meanings, default
severity levels, and how to configure them to match your project's needs.

## Diagnostic codes

JETLS reports diagnostics using hierarchical codes in the format
`"category/kind"`, following the [LSP specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#diagnostic).
This structure allows fine-grained control over which diagnostics to show and at
what [severity level](@ref severity-level) through configuration.

All available diagnostic codes are listed below. Each category (e.g.,
`syntax/*`, `lowering/*`) contains one or more specific diagnostic codes:

```@contents
Pages = ["diagnostics.md"]
Depth = 3:4
```

## [Diagnostic severity levels](@id severity-level)

Each diagnostic has a severity level that indicates how serious the issue is.
JETLS supports four severity levels defined by the [LSP specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#diagnosticSeverity):
- **`Error`** (`1`): Critical issues that prevent code from working correctly.
  Most LSP clients display these with red underlines and error markers.
- **`Warning`** (`2`): Potential problems that should be reviewed. Typically
  shown with yellow/orange underlines and warning markers.
- **`Information`** (`3`): Informational messages about code that may benefit
  from attention. Often displayed with blue underlines or subtle markers.
- **`Hint`** (`4`): Suggestions for improvements or best practices. Usually
  shown with the least intrusive visual indicators.

How diagnostics are displayed depends on your LSP client (VS Code, Neovim,
etc.), but most clients use color-coded underlines and gutter markers that
correspond to these severity levels.

If a specific diagnostic is displayed intrusively in your client,
you can change the severity through [Configuring diagnostics](@ref)
(or disable them entirely if you prefer).

## Diagnostic reference

This section provides detailed explanations for each diagnostic code. For every
diagnostic, you'll find:
- A description of what the diagnostic detects
- Its default severity level
- Code examples demonstrating when the diagnostic is reported
- Example diagnostic messages (shown in code comments)

### Syntax diagnostics (`syntax/*`)

#### [Syntax parse error (`syntax/parse-error`)](@id diagnostic/syntax/parse-error)

**Default severity:** `Error`

Syntax parsing errors detected by JuliaSyntax.jl. These indicate invalid Julia
syntax that prevents the code from being parsed.

Example:
```julia
function parse_error(x)
    println(x  # Expected `)` or `,` (JETLS syntax/parse-error)
end
```

### Lowering diagnostics (`lowering/*`)

Lowering diagnostics are detected during Julia's lowering phase, which
transforms parsed syntax into a simpler intermediate representation.

#### [Lowering error (`lowering/error`)](@id diagnostic/lowering/error)

**Default severity:** `Error`

General lowering errors that don't fit into more specific categories.

Example:
```julia
function lowering_error(x)
    $(x)  # `$` expression outside string or quote block (JETLS lowering/error)
end
```

#### [Macro expansion error (`lowering/macro-expansion-error`)](@id diagnostic/lowering/macro-expansion-error)

**Default severity:** `Error`

Errors that occur when expanding macros during the lowering phase.

Example:
```julia
function macro_expand_error()
    @undefined_macro ex  # Macro name `@undefined_macro` not found (JETLS lowering/macro-expansion-error)
end
```

Errors that occur during actual macro expansion are also reported:
```julia
macro myinline(ex)
    Meta.isexpr(ex, :function) || error("Expected long function definition")
    return :(@inline $ex)
end
@myinline callsin(x) = sin(x)  # Error expanding macro
                               # Expected long function definition (JETLS lowering/macro-expansion-error)
```

#### [Unused argument (`lowering/unused-argument`)](@id diagnostic/lowering/unused-argument)

**Default severity:** `Information`

Function arguments that are declared but never used in the function body.

Example:
```julia
function unused_argument(x, y)  # Unused argument `y` (JETLS lowering/unused-argument)
    return x + 1
end
```

#### [Unused local variable (`lowering/unused-local`)](@id diagnostic/lowering/unused-local)

**Default severity:** `Information`

Local variables that are assigned but never read.

Example:
```julia
function unused_local()
    x = 10  # Unused local binding `x` (JETLS lowering/unused-local)
    return println(10)
end
```

### [Top-level diagnostics (`toplevel/*`)](@id toplevel-diagnostics)

Top-level diagnostics are reported by JETLS's full analysis feature, which runs
when you save a file. To prevent excessive analysis on frequent saves, JETLS
uses a debounce mechanism. See the [`[full_analysis] debounce`](@ref config/full_analysis-debounce)
configuration documentation to adjust the debounce period.

#### [Top-level error (`toplevel/error`)](@id diagnostic/toplevel/error)

**Default severity:** `Error`

Errors that occur when JETLS loads your code for analysis. This diagnostic is
commonly reported in several scenarios:

- Missing package dependencies (the most frequent cause)
- Type definition failures
- References to undefined names at the top level
- Other errors during module evaluation

Examples:

```julia
struct ToplevelError  # UndefVarError: `Unexisting` not defined in `JETLS`
                      # Suggestion: check for spelling errors or missing imports. (JETLS toplevel/error)
    x::Unexisting
end

using UnexistingPkg  # Package JETLS does not have UnexistingPkg in its dependencies:
                     # - You may have a partially installed environment. Try `Pkg.instantiate()`
                     # to ensure all packages in the environment are installed.
                     # - Or, if you have JETLS checked out for development and have
                     # added UnexistingPkg as a dependency but haven't updated your primary
                     # environment's manifest file, try `Pkg.resolve()`.
                     # - Otherwise you may need to report an issue with JETLS (JETLS toplevel/error)
```

These errors prevent JETLS from fully analyzing your code, which means
[Inference diagnostics](@ref inference-diagnostics) will not be available until
the top-level errors are resolved. To fix these errors, ensure your package
environment is properly set up by running `Pkg.instantiate()` in your package
directory, and verify that your package can be loaded successfully in a Julia REPL.

### [Inference diagnostics (`inference/*`)](@id inference-diagnostics)

Inference diagnostics use JET.jl to perform type-aware analysis and detect
potential errors through static analysis. These diagnostics are also reported by
JETLS's full analysis feature (see [Top-level diagnostics](@ref
toplevel-diagnostics) for details on when analysis runs).

#### [Undefined global variable (`inference/undef-global-var`)](@id diagnostic/inference/undef-global-var)

**Default severity:** `Warning`

References to undefined global variables.

Example:

```julia
function undef_global_var()
    return undefined_global  # `undefined_global` is not defined (JETLS inference/undef-global-var)
end
```

#### [Undefined local variable (`inference/undef-local-var`)](@id diagnostic/inference/undef-local-var)

**Default severity:** `Information` or `Warning`

References to undefined local variables. The severity depends on whether the
variable is definitely undefined (`Warning`) or only possibly undefined
(`Information`).

Example:
```julia
function undef_local_var()
    if rand() > 0.5
        x = 1
    end
    return x  # local variable `x` may be undefined (JETLS inference/undef-local-var)
end
```

### TestRunner diagnostics (`testrunner/*`)

#### [Test failure (`testrunner/test-failure`)](@id diagnostic/testrunner/test-failure)

**Default severity:** `Error`

Test failures reported by [TestRunner integration](@ref) that happened during
running individual `@testset` blocks or `@test` cases.

## Configuring diagnostics

You can configure which diagnostics are shown and at what [severity level](@ref severity-level)
under the `[diagnostics]` section. This allows you to customize JETLS's
behavior to match your project's coding standards and preferences.

##### Quick example

```toml
[diagnostics]
enabled = true

[diagnostics.codes]
# Make all lowering diagnostics warnings
"lowering/*" = { severity = "warning" }

# Disable inference diagnostics entirely
"inference/*" = { enabled = false }

# Show unused arguments as hints (overrides category setting)
"lowering/unused-argument" = { severity = "hint" }
```

##### Common use cases

Disable unused variable warnings during prototyping:

```toml
[diagnostics.codes]
"lowering/unused-argument" = { enabled = false }
"lowering/unused-local" = { enabled = false }
```

Make inference diagnostics less intrusive:

```toml
[diagnostics.codes]
"inference/*" = { severity = "hint" }
```

Focus only on syntax and lowering errors:

```toml
[diagnostics.codes]
"lowering/*" = { enabled = false }
```

For complete configuration options, syntax, and more examples, see the
[diagnostics configuration](@ref config/diagnostics) in the
[JETLS configuration](@ref) page.
