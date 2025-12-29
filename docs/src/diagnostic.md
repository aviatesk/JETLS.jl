# Diagnostic

JETLS reports various diagnostic messages (errors, warnings, hints) to help you
catch potential issues in your Julia code. Each diagnostic has a unique code
that identifies its category and type.

This document describes all available diagnostic codes, their meanings, default
severity levels, and how to configure them to match your project's needs.

## [Diagnostic codes](@id diagnostic-code)

JETLS reports diagnostics using hierarchical codes in the format
`"category/kind"`, following the [LSP specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#diagnostic).
This structure allows fine-grained control over which diagnostics to show and at
what [severity level](@ref diagnostic-severity) through configuration.

All available diagnostic codes are listed below. Each category (e.g.,
`syntax/*`, `lowering/*`) contains one or more specific diagnostic codes:

```@contents
Pages = ["diagnostic.md"]
Depth = 3:4
```

## [Diagnostic severity levels](@id diagnostic-severity)

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

You can change the severity of any diagnostic by
[configuring `diagnostic` section](@ref configuring-diagnostic).
Additionally, JETLS supports disabling diagnostics entirely using the special
severity value `"off"` (or `0`).

## [Diagnostic reference](@id diagnostic-reference)

This section provides detailed explanations for each diagnostic code. For every
diagnostic, you'll find:

- A description of what the diagnostic detects
- Its default severity level
- Code examples demonstrating when the diagnostic is reported
- Example diagnostic messages (shown in code comments)

Here is a summary table of the diagnostics explained in this section:

| Code                                                                               | Default Severity      | Description                                                    |
| ---------------------------------------------------------------------------------- | --------------------- | -------------------------------------------------------------- |
| [`syntax/parse-error`](@ref diagnostic/syntax/parse-error)                         | `Error`               | Syntax parsing errors detected by JuliaSyntax.jl               |
| [`lowering/error`](@ref diagnostic/lowering/error)                                 | `Error`               | General lowering errors                                        |
| [`lowering/macro-expansion-error`](@ref diagnostic/lowering/macro-expansion-error) | `Error`               | Errors during macro expansion                                  |
| [`lowering/unused-argument`](@ref diagnostic/lowering/unused-argument)             | `Information`         | Function arguments that are never used                         |
| [`lowering/unused-local`](@ref diagnostic/lowering/unused-local)                   | `Information`         | Local variables that are assigned but never read               |
| [`toplevel/error`](@ref diagnostic/toplevel/error)                                 | `Error`               | Errors during code loading (missing deps, type failures, etc.) |
| [`inference/undef-global-var`](@ref diagnostic/inference/undef-global-var)         | `Warning`             | References to undefined global variables                       |
| [`inference/undef-local-var`](@ref diagnostic/inference/undef-local-var)           | `Information/Warning` | References to undefined local variables                        |
| [`inference/field-error`](@ref diagnostic/inference/field-error)                   | `Warning`             | Access to non-existent struct fields                           |
| [`inference/bounds-error`](@ref diagnostic/inference/bounds-error)                 | `Warning`             | Out-of-bounds field access by index                            |
| [`testrunner/test-failure`](@ref diagnostic/testrunner/test-failure)               | `Error`               | Test failures from TestRunner integration                      |

### [Syntax diagnostic (`syntax/*`)](@id diagnostic/syntax)

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

### [Lowering diagnostic (`lowering/*`)](@id diagnostic/lowering)

Lowering diagnostic is detected during Julia's lowering phase, which
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

By default, arguments with names starting with `_` are not reported; see
[`allow_unused_underscore`](@ref config/diagnostic-allow_unused_underscore).

Example:

```julia
function unused_argument(x, y)  # Unused argument `y` (JETLS lowering/unused-argument)
    return x + 1
end
```

#### [Unused local variable (`lowering/unused-local`)](@id diagnostic/lowering/unused-local)

**Default severity:** `Information`

Local variables that are assigned but never read.

By default, variables with names starting with `_` are not reported; see
[`allow_unused_underscore`](@ref config/diagnostic-allow_unused_underscore).

Example:

```julia
function unused_local()
    x = 10  # Unused local binding `x` (JETLS lowering/unused-local)
    return println(10)
end
```

### [Top-level diagnostic (`toplevel/*`)](@id toplevel-diagnostic)

Top-level diagnostic are reported by JETLS's full analysis feature, which runs
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
[Inference diagnostic](@ref inference-diagnostic) will not be available until
the top-level errors are resolved. To fix these errors, ensure your package
environment is properly set up by running `Pkg.instantiate()` in your package
directory, and verify that your package can be loaded successfully in a Julia REPL.

### [Inference diagnostic (`inference/*`)](@id inference-diagnostic)

Inference diagnostic uses JET.jl to perform type-aware analysis and detect
potential errors through static analysis. These diagnostics are also reported by
JETLS's full analysis feature (see [Top-level diagnostic](@ref
toplevel-diagnostic) for details on when analysis runs).

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

#### [Field error (`inference/field-error`)](@id diagnostic/inference/field-error)

**Default severity:** `Warning`

Access to non-existent struct fields. This diagnostic is reported when code
attempts to access a field that doesn't exist on a struct type.

Example:

```julia
struct MyStruct
    property::Int
end
function field_error()
    x = MyStruct(42)
    return x.propert  # FieldError: type MyStruct has no field `propert`, available fields: `property` (JETLS inference/field-error)
end
```

#### [Bounds error (`inference/bounds-error`)](@id diagnostic/inference/bounds-error)

**Default severity:** `Warning`

Out-of-bounds field access by index. This diagnostic is reported when code
attempts to access a struct field using an integer index that is out of bounds,
such as `getfield(x, i)` or tuple indexing `tpl[i]`.

!!! note
    This diagnostic is not reported for arrays, since the compiler doesn't
    track array shape information.

Example:

```julia
function bounds_error(tpl::Tuple{Int})
    return tpl[2]  # BoundsError: attempt to access Tuple{Int64} at index [2] (JETLS inference/bounds-error)
end
```

### [TestRunner diagnostic (`testrunner/*`)](@id diagnostic/testrunner)

#### [Test failure (`testrunner/test-failure`)](@id diagnostic/testrunner/test-failure)

**Default severity:** `Error`

Test failures reported by [TestRunner integration](@ref) that happened during
running individual `@testset` blocks or `@test` cases.

## [Configuring diagnostic](@id configuring-diagnostic)

You can configure which diagnostics are shown and at what [severity level](@ref diagnostic-severity)
under the `[diagnostic]` section. This allows you to customize JETLS's
behavior to match your project's coding standards and preferences.

```@example
nothing # This is an internal comment for this documenation: # hide
nothing # Use H5 for subsections in this section so that the `@contents` block above works as intended. # hide
```

##### Common use cases

Suppress specific macro expansion errors:

```toml
[[diagnostic.patterns]]
pattern = "Macro name `MyPkg.@mymacro` not found"
match_by = "message"
match_type = "literal"
severity = "off"
```

Apply different settings for test files:

```toml
# Downgrade unused arguments to hints in test files
[[diagnostic.patterns]]
pattern = "lowering/unused-argument"
match_by = "code"
match_type = "literal"
severity = "hint"
path = "test/**/*.jl"

# Disable all diagnostics for generated code
[[diagnostic.patterns]]
pattern = ".*"
match_by = "code"
match_type = "regex"
severity = "off"
path = "gen/**/*.jl"
```

Disable unused variable warnings during prototyping:

```toml
[[diagnostic.patterns]]
pattern = "lowering/(unused-argument|unused-local)"
match_by = "code"
match_type = "regex"
severity = "off"
```

Make inference diagnostic less intrusive:

```toml
[[diagnostic.patterns]]
pattern = "inference/.*"
match_by = "code"
match_type = "regex"
severity = "hint"
```

For complete configuration options, severity values, pattern matching syntax,
and more examples, see the [`[diagnostic]` configuration](@ref config/diagnostic)
section in the [JETLS configuration](@ref) page.
