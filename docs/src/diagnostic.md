# [Diagnostic](@id diagnostic)

JETLS reports various diagnostic messages (errors, warnings, hints) to help you
catch potential issues in your Julia code. Each diagnostic has a unique code
that identifies its category and type.

This document describes all available diagnostic codes, their meanings, default
severity levels, and how to configure them to match your project's needs.

## [Codes](@id diagnostic/code)

JETLS reports diagnostics using hierarchical codes in the format
`"category/kind"`, following the [LSP specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#diagnostic).
This structure allows fine-grained control over which diagnostics to show and at
what [severity level](@ref diagnostic/severity) through configuration.

All available diagnostic codes are listed below. Each category (e.g.,
`syntax/*`, `lowering/*`) contains one or more specific diagnostic codes:

```@contents
Pages = ["diagnostic.md"]
Depth = 3:4
```

## [Severity levels](@id diagnostic/severity)

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
[configuring `diagnostic` section](@ref diagnostic/configuring).
Additionally, JETLS supports disabling diagnostics entirely using the special
severity value `"off"` (or `0`).

## [Sources](@id diagnostic/source)

JETLS uses different diagnostic channels to balance analysis accuracy with
response latency. Lightweight checks run as you edit for immediate feedback,
while deeper analysis runs on save to avoid excessive resource consumption.

Each diagnostic has a `source` field that identifies which diagnostic channel
it comes from. This section explains what each source means, helping you
understand when diagnostics update.
Additionally, some editors also allow filtering diagnostics by source.

!!! info
    This section contains references to LSP protocol details. You don't need
    to understand these details to use JETLS effectively - the key takeaway
    is simply that different diagnostics update at different times (as you
    edit, when you save, or when you run tests via [TestRunner integration](@ref testrunner)).

JETLS uses three diagnostic sources:

- **`JETLS/live`**: Diagnostics available on demand via the pull model
  diagnostic channels
  [`textDocument/diagnostic`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_diagnostic)
  (for open files) and
  [`workspace/diagnostic`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspace_diagnostic)
  (for unopened files when [`diagnostic.all_files`](@ref config/diagnostic-all_files) is enabled).
  Most clients request these as you edit, providing real-time feedback without
  requiring a file save. Includes syntax errors and lowering-based analysis
  (`syntax/*`, `lowering/*`).
- **`JETLS/save`**: Diagnostics published by JETLS after on-save full analysis
  via the push model channel [`textDocument/publishDiagnostics`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_publishDiagnostics).
  These run full analysis including type inference and require loading your
  code. Includes top-level errors and inference-based analysis (`toplevel/*`,
  `inference/*`).
- **`JETLS/extra`**: Diagnostics from external sources like the TestRunner
  integration (`testrunner/*`). Published via [`textDocument/publishDiagnostics`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_publishDiagnostics).

## [Reference](@id diagnostic/reference)

This section provides detailed explanations for each diagnostic code. For every
diagnostic, you'll find:

- A description of what the diagnostic detects
- Its default severity level and source
- Code examples demonstrating when the diagnostic is reported
- Example diagnostic messages (shown in code comments)

Here is a summary table of the diagnostics explained in this section:

| Code                                                                                             | Default Severity      | Source        | Description                                        |
| ------------------------------------------------------------------------------------------------ | --------------------- | ------------- | -------------------------------------------------- |
| [`syntax/parse-error`](@ref diagnostic/reference/syntax/parse-error)                             | `Error`               | `JETLS/live`  | Syntax parsing errors detected by JuliaSyntax.jl   |
| [`lowering/error`](@ref diagnostic/reference/lowering/error)                                     | `Error`               | `JETLS/live`  | General lowering errors                            |
| [`lowering/macro-expansion-error`](@ref diagnostic/reference/lowering/macro-expansion-error)     | `Error`               | `JETLS/live`  | Errors during macro expansion                      |
| [`lowering/unused-argument`](@ref diagnostic/reference/lowering/unused-argument)                 | `Information`         | `JETLS/live`  | Function arguments that are never used             |
| [`lowering/unused-local`](@ref diagnostic/reference/lowering/unused-local)                       | `Information`         | `JETLS/live`  | Local variables that are assigned but never read   |
| [`lowering/undef-global-var`](@ref diagnostic/reference/lowering/undef-global-var)               | `Warning`             | `JETLS/live`  | References to undefined global variables           |
| [`lowering/undef-local-var`](@ref diagnostic/reference/lowering/undef-local-var)                 | `Warning/Information` | `JETLS/live`  | References to undefined local variables            |
| [`lowering/captured-boxed-variable`](@ref diagnostic/reference/lowering/captured-boxed-variable) | `Information`         | `JETLS/live`  | Variables captured by closures that require boxing |
| [`lowering/unused-import`](@ref diagnostic/reference/lowering/unused-import)                     | `Information`         | `JETLS/live`  | Imported names that are never used                 |
| [`lowering/undefined-export`](@ref diagnostic/reference/lowering/undefined-export)               | `Warning`             | `JETLS/live`  | Exporting names that are not defined               |
| [`lowering/unsorted-import-names`](@ref diagnostic/reference/lowering/unsorted-import-names)     | `Hint`                | `JETLS/live`  | Import/export names not sorted alphabetically      |
| [`toplevel/error`](@ref diagnostic/reference/toplevel/error)                                     | `Error`               | `JETLS/save`  | Errors during code loading                         |
| [`toplevel/method-overwrite`](@ref diagnostic/reference/toplevel/method-overwrite)               | `Warning`             | `JETLS/save`  | Method definitions that overwrite previous ones    |
| [`toplevel/abstract-field`](@ref diagnostic/reference/toplevel/abstract-field)                   | `Information`         | `JETLS/save`  | Struct fields with abstract types                  |
| [`inference/undef-global-var`](@ref diagnostic/reference/inference/undef-global-var)             | `Warning`             | `JETLS/save`  | References to undefined global variables           |
| [`inference/field-error`](@ref diagnostic/reference/inference/field-error)                       | `Warning`             | `JETLS/save`  | Access to non-existent struct fields               |
| [`inference/bounds-error`](@ref diagnostic/reference/inference/bounds-error)                     | `Warning`             | `JETLS/save`  | Out-of-bounds field access by index                |
| [`testrunner/test-failure`](@ref diagnostic/reference/testrunner/test-failure)                   | `Error`               | `JETLS/extra` | Test failures from TestRunner integration          |

### [Syntax diagnostic (`syntax/*`)](@id diagnostic/reference/syntax)

#### [Syntax parse error (`syntax/parse-error`)](@id diagnostic/reference/syntax/parse-error)

**Default severity**: `Error`

Syntax parsing errors detected by JuliaSyntax.jl. These indicate invalid Julia
syntax that prevents the code from being parsed.

Example:

```julia
function parse_error(x)
    println(x  # Expected `)` or `,` (JETLS syntax/parse-error)
end
```

### [Lowering diagnostic (`lowering/*`)](@id diagnostic/reference/lowering)

Lowering diagnostics are detected during Julia's lowering phase, which
transforms parsed syntax into a simpler intermediate representation.

#### [Lowering error (`lowering/error`)](@id diagnostic/reference/lowering/error)

**Default severity**: `Error`

General lowering errors that don't fit into more specific categories.

Example:

```julia
function lowering_error(x)
    $(x)  # `$` expression outside string or quote block (JETLS lowering/error)
end
```

#### [Macro expansion error (`lowering/macro-expansion-error`)](@id diagnostic/reference/lowering/macro-expansion-error)

**Default severity**: `Error`

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

#### [Unused argument (`lowering/unused-argument`)](@id diagnostic/reference/lowering/unused-argument)

**Default severity**: `Information`

Function arguments that are declared but never used in the function body.

By default, arguments with names starting with `_` are not reported; see
[`allow_unused_underscore`](@ref config/diagnostic-allow_unused_underscore).

Example:

```julia
function unused_argument(x, y)  # Unused argument `y` (JETLS lowering/unused-argument)
    return x + 1
end
```

!!! tip "Code action available"
    You can use the "Prefix with '_'" code action to quickly rename unused
    arguments, indicating they are intentionally unused.

#### [Unused local variable (`lowering/unused-local`)](@id diagnostic/reference/lowering/unused-local)

**Default severity**: `Information`

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

!!! tip "Code action available"
    Several code actions are available for this diagnostic:
    - "Prefix with '_'" to indicate the variable is intentionally unused
    - "Delete assignment" to remove only the left-hand side (keeping the
      right-hand side expression)
    - "Delete statement" to remove the entire assignment statement

#### [Undefined global variable (`lowering/undef-global-var`)](@id diagnostic/reference/lowering/undef-global-var)

**Default severity**: `Warning`

References to undefined global variables, detected during lowering analysis.
This diagnostic provides immediate feedback as you type.

Example:

```julia
function undef_global_var()
    ret = sin(undefined_var)  # `Main.undefined_var` is not defined (JETLS lowering/undef-global-var)
    return ret
end
```

This diagnostic detects simple undefined global variable references. For more
comprehensive detection (including qualified references like `Base.undefvar`),
see [`inference/undef-global-var`](@ref diagnostic/reference/inference/undef-global-var)
(source: `JETLS/save`).

#### [Undefined local variable (`lowering/undef-local-var`)](@id diagnostic/reference/lowering/undef-local-var)

**Default severity**: `Warning` or `Information`

References to local variables that may be used before being defined. This
diagnostic provides immediate feedback based on CFG-aware analysis on lowered
code.

The severity depends on the certainty of the undefined usage:
- **`Warning`**: The variable is definitely used before any assignment (strict
  undef - guaranteed `UndefVarError` at runtime)
- **`Information`**: The variable may be undefined depending on control flow
  (e.g., assigned only in one branch of an `if` statement)

Examples:

```julia
function strict_undef()
    println(x)  # Variable `x` is used before it is defined (JETLS lowering/undef-local-var)
                # Severity: Warning (strict undef)
    x = 1       # RelatedInformation: `x` is defined here
    return x
end

function maybe_undef(cond)
    if cond
        y = 1   # RelatedInformation: `y` is defined here
    end
    return y  # Variable `y` may be used before it is defined (JETLS lowering/undef-local-var)
              # Severity: Information (maybe undef)
end
```

The diagnostic is reported at the first use location, with `relatedInformation`
pointing to definition sites to help understand the control flow.

!!! tip "Workaround: Using `@isdefined` guard"
    When a variable is conditionally assigned, you can rewrite the program logic
    using `@isdefined` so that the compiler can track the definedness:
    ```julia
    function guarded(cond)
        if cond
            y = 42
        end
        if @isdefined(y)
            return sin(y)  # No diagnostic: compiler knows `y` is defined here
        end
    end
    ```

!!! tip "Workaround: Using `@assert @isdefined` as a hint"
    There are cases where you know a variable is always defined at a certain point,
    but the analysis cannot prove it. This includes correlated conditions, complex
    control flow, or general runtime invariants that the compiler cannot figure out
    statically. In such cases, you can use `@assert @isdefined(var) "..."` as a hint:
    ```julia
    function correlated(cond)
        if cond
            y = 42
        end
        if cond
            # The analysis reports "may be undefined" because it doesn't track
            # that `cond` is the same in both branches
            @assert @isdefined(y) "Assertion to tell the compiler about the definedness of this variable"
            return sin(y)  # No diagnostic after the assertion
        end
    end
    ```
    This hint allows the compiler to avoid generating unnecessary `UndefVarError`
    handling code, and also serves as documentation that you've verified the
    variable is defined at this point.

#### [Captured boxed variable (`lowering/captured-boxed-variable`)](@id diagnostic/reference/lowering/captured-boxed-variable)

**Default severity**: `Information`

Reported when a variable is captured by a closure and requires "boxing" due to
being assigned multiple times. Captured boxed variables are stored in heap-allocated
containers (a.k.a. `Core.Box`), which can cause type instability and hinder
compiler optimizations.[^perftip]

[^perftip]:
    For detailed information about how captured variables affect performance,
    see Julia's [Performance Tips on captured variables](https://docs.julialang.org/en/v1/manual/performance-tips/#man-performance-captured).

Example:
```julia
function captured_variable()
    x = 1           # `x` is captured and boxed (JETLS lowering/captured-boxed-variable)
    f = () ->
        println(x)  # RelatedInformation: Closure at L3:9 captures `x`
    x = 2           # (`x` is reassigned after capture)
    return f
end
```

The diagnostic includes `relatedInformation` showing where the variable is
captured:
```julia
function multi_capture()
    x = 1               # `x` is captured and boxed (JETLS lowering/captured-boxed-variable)
    f = () ->
        println(x)      # RelatedInformation: Closure at L3:9 captures `x`
    g = () ->
        println(x + 1)  # RelatedInformation: Closure at L5:9 captures `x`
    x = 2
    return f, g
end
```

Variables captured by closures but assigned only once before closure definition
do not require boxing and are not reported:
```julia
function not_boxed()
    x = 1
    f = () -> x  # OK: `x` is only assigned once
    return f
end
```

!!! tip "Workaround"
    When you need to capture a variable that changes, consider using a `let` block:
    ```julia
    function with_let()
        x = 1
        f = let x = x
            () -> x  # Captures the value of `x` at this point
        end
        x = 2
        return f()  # Returns 1, not 2
    end
    ```

    or mutable container like `Ref` to avoid direct assignment to the captured
    variable:
    ```julia
    function with_mut()
        x = Ref(1)
        f = () -> x[]
        x[] = 2
        return f()
    end
    ```

!!! warning "Box optimization difference from the flisp lowerer"
    The generation of captured boxes is an implementation detail of the code
    lowerer ([JuliaLowering.jl](https://github.com/JuliaLang/julia/tree/master/JuliaLowering))
    used internally by JETLS, and the conditions under which captured boxes are
    created may change in the future. The control flow dominance analysis used
    for captured variable detection in the current JuliaLowering.jl is quite
    primitive, so captured boxes may occur even when programmers don't expect
    them. Also note that the cases where the flisp lowerer (a.k.a. `code_lowered`)
    generates `Core.Box` do not necessarily match the cases where JETLS reports
    captured boxes.

#### [Unused import (`lowering/unused-import`)](@id diagnostic/reference/lowering/unused-import)

**Default severity**: `Information`

Reported when an explicitly imported name is never used within the same module
space. This diagnostic helps identify unnecessary imports that can be removed
to keep your code clean.

Example:

```julia
using Base: sin, cos  # Unused import `cos` (JETLS lowering/unused-import)

examplefunc() = sin(1.0)  # Only `sin` is used
```

The diagnostic is reported for explicit imports (`using M: name` or
`import M: name`), not for bulk imports like `using M` which bring in all
exported names.

This diagnostic scans all files within the module space to detect usages, so an
import is only reported as unused if the name is not used anywhere in your
module.

!!! tip "Code action available"
    Use the "Remove unused import" code action to delete the unused name.
    If it's the only name in the statement, the entire statement is removed.

!!! warning "Limitation"
    Usages introduced only through macro expansion cannot be detected. For
    example, in the following code, `sin` appears unused even though it is
    used inside the macro-generated code:
    ```julia
    using Base: sin  # Incorrectly reported as unused

    macro gensincall(x)
        :(sin($(esc(x))))
    end
    @gensincall 42
    ```

    Workarounds include using the binding directly in the macro body:
    ```julia
    macro gensincall(x)
        f = sin  # `sin` is used here
        :($f($(esc(x))))
    end
    ```
    or passing the binding as part of the macro argument:
    ```julia
    macro gencall(ex)
        :($(esc(ex)))
    end
    @gencall sin(42)  # `sin` is used here
    ```

#### [Undefined export (`lowering/undefined-export`)](@id diagnostic/reference/lowering/undefined-export)

**Default severity**: `Warning`

Reported when an `export` statement references a name that is not defined in
the current module. This helps catch typos or missing definitions early.

Example:

```julia
export undefined_name  # Exported name `undefined_name` is not defined in `MyModule`
                       # (JETLS lowering/undefined-export)
```

#### [Unsorted import names (`lowering/unsorted-import-names`)](@id diagnostic/reference/lowering/unsorted-import-names)

**Default severity**: `Hint`

Reported when names in `import`, `using`, `export`, or `public` statements are
not sorted alphabetically. This is a style diagnostic that helps maintain
consistent ordering of imports and exports.

Expected sort order:
- Case-sensitive comparison (`A` < `Z` < `a` < `z`)
- For `as` expressions like `using Foo: bar as baz`, sorted by original name
  (`bar`), not the alias
- Relative imports: dots are included in the sort key
  (`..Base` < `Base` < `Core`)

Example:

```julia
import Foo: c, a, b  # Names are not sorted alphabetically (JETLS lowering/unsorted-import-names)

export bar, @foo  # Names are not sorted alphabetically (JETLS lowering/unsorted-import-names)
```

!!! tip "Code action available"
    The "Sort import names" code action automatically fixes the ordering.
    When the sorted result exceeds 92 characters (
    [Julia's conventional maximum line length](https://docs.julialang.org/en/v1.14-dev/devdocs/contributing/formatting/#General-Formatting-Guidelines-for-Julia-code-contributions)),
    the code action wraps to multiple lines with 4-space continuation indent.

### [Top-level diagnostic (`toplevel/*`)](@id diagnostic/reference/toplevel)

Top-level diagnostics are reported by JETLS's full analysis feature (source:
`JETLS/save`), which runs when you save a file. To prevent excessive analysis
on frequent saves, JETLS uses a debounce mechanism. See the
[`[full_analysis] debounce`](@ref config/full_analysis-debounce) configuration
documentation to adjust the debounce period.

#### [Top-level error (`toplevel/error`)](@id diagnostic/reference/toplevel/error)

**Default severity**: `Error`

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
[Inference diagnostic](@ref diagnostic/reference/inference) will not be available until
the top-level errors are resolved. To fix these errors, ensure your package
environment is properly set up by running `Pkg.instantiate()` in your package
directory, and verify that your package can be loaded successfully in a Julia REPL.

#### [Method overwrite (`toplevel/method-overwrite`)](@id diagnostic/reference/toplevel/method-overwrite)

**Default severity**: `Warning`

Reported when a method with the same signature is defined multiple times within
a package. This typically indicates an unintentional redefinition that
overwrites the previous method.

Example:

```julia
function duplicate(x::Int)
    return x + 1
end

function duplicate(x::Int, y::Int=2)  # Method definition duplicate(x::Int) in module MyPkg overwritten
                                      # (JETLS toplevel/method-overwrite)
    return x + y
end
```

The diagnostic includes a link to the original definition location via
`relatedInformation`, making it easy to navigate to the first definition.

#### [Abstract field type (`toplevel/abstract-field`)](@id diagnostic/reference/toplevel/abstract-field)

**Default severity**: `Information`

Reported when a struct field has an abstract type, which can cause performance
issues due to type instability. Storing values in abstractly-typed fields
often prevents the compiler from generating optimized code.

Example:

```julia
struct MyStruct
    xs::Vector{Integer}  # `MyStruct` has abstract field `xs::Vector{Integer}`
                         # (JETLS toplevel/abstract-field)
end

struct AnotherStruct
    data::AbstractVector{Int}  # `AnotherStruct` has abstract field `data::AbstractVector{Int}`
                               # (JETLS toplevel/abstract-field)
end
```

To fix this, use concrete types or parameterize your struct:

```julia
struct MyStruct
    xs::Vector{Int}  # Concrete element type
end

struct AnotherStruct{T<:AbstractVector{Int}}
    data::T  # Parameterized field allows concrete types
end
```

!!! tip
    If you intentionally use abstract field types (e.g., in cases where data
    types are inherently only known at compile time[^nospecializetip]),
    you can suppress this diagnostic using [pattern-based configuration](@ref config/diagnostic-patterns):
    ```toml
    [[diagnostic.patterns]]
    pattern = "`MyStruct` has abstract field `.*`"
    match_by = "message"
    match_type = "regex"
    severity = "off"
    ```

[^nospecializetip]: For such cases, you can add `@nospecialize` to the use-site methods to allow them to handle abstract data types while avoiding excessive compilation.

### [Inference diagnostic (`inference/*`)](@id diagnostic/reference/inference)

Inference diagnostics use [JET.jl](https://github.com/aviatesk/JET.jl) to
perform type-aware analysis and detect potential errors through static analysis.
These diagnostics are reported by JETLS's full analysis feature
(source: `JETLS/save`), which runs when you save a file (similar to
[Top-level diagnostic](@ref diagnostic/reference/toplevel)).

#### [Undefined global variable (`inference/undef-global-var`)](@id diagnostic/reference/inference/undef-global-var)

**Default severity**: `Warning`

References to undefined global variables, detected through full analysis. This
diagnostic can detect comprehensive cases including qualified references
(e.g., `Base.undefvar`). Position information is reported on a line basis.

Example:

```julia
function undef_global_var()
    return undefined_global  # `undefined_global` is not defined (JETLS inference/undef-global-var)
end
```

For faster feedback while editing, see
[`lowering/undef-global-var`](@ref diagnostic/reference/lowering/undef-global-var)
(source: `JETLS/live`), which reports a subset of undefined variable cases with
accurate position information.

#### [Field error (`inference/field-error`)](@id diagnostic/reference/inference/field-error)

**Default severity**: `Warning`

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

#### [Bounds error (`inference/bounds-error`)](@id diagnostic/reference/inference/bounds-error)

**Default severity**: `Warning`

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

### [TestRunner diagnostic (`testrunner/*`)](@id diagnostic/reference/testrunner)

TestRunner diagnostics are reported when you manually run tests via code lens
or code actions through the [TestRunner integration](@ref testrunner) (source: `JETLS/extra`).
Unlike other diagnostics, these are not triggered automatically by editing or saving files.

#### [Test failure (`testrunner/test-failure`)](@id diagnostic/reference/testrunner/test-failure)

**Default severity**: `Error`

Test failures reported by [TestRunner integration](@ref testrunner) that happened during
running individual `@testset` blocks or `@test` cases.

!!! note
    Diagnostics from `@test` cases automatically disappear after 10 seconds,
    while `@testset` diagnostics persist until you run the testset again,
    restructure testsets, or clear them manually.

## [Configuration](@id diagnostic/configuring)

You can configure which diagnostics are shown and at what [severity level](@ref diagnostic/severity)
under the `[diagnostic]` section. This allows you to customize JETLS's
behavior to match your project's coding standards and preferences.

```@example
nothing # This is an internal comment for this documentaion: # hide
nothing # Use H5 for subsections in this section so that the `@contents` block above works as intended. # hide
```

##### [Common use cases](@id diagnostic/configuring/common-use-cases)

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
