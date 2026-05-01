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

- **`Error`** (`1`): invalid code that cannot be compiled or loaded
  (e.g. syntax errors, lowering errors)
- **`Warning`** (`2`): code that is likely a bug
  (e.g. undefined variables, type mismatches)
- **`Information`** (`3`): valid code that is probably unintentional
  (e.g. unused bindings, unreachable code)
- **`Hint`** (`4`): stylistic suggestions where the code works as
  intended but could be written more cleanly
  (e.g. unsorted import names)

The LSP specification does not prescribe how clients should render
each severity level, so the actual display varies by editor. In
practice, most editors display `Error`, `Warning`, and `Information`
with color-coded underlines (red, yellow, blue) and gutter markers,
while `Hint` is typically rendered with a more subtle indicator such as faded
text or an ellipsis (`...`).[^vscode_severity]

[^vscode_severity]: VS Code, which serves as the de facto reference for LSP
    client behavior, follows these conventions.
    In VS Code, `Hint` diagnostics are not listed in the Problems Panel.

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
| [`lowering/undef-global-var`](@ref diagnostic/reference/lowering/undef-global-var)               | `Warning`             | `JETLS/live`  | References to undefined global variables           |
| [`lowering/undef-local-var`](@ref diagnostic/reference/lowering/undef-local-var)                 | `Warning/Information` | `JETLS/live`  | References to undefined local variables            |
| [`lowering/ambiguous-soft-scope`](@ref diagnostic/reference/lowering/ambiguous-soft-scope)       | `Warning`             | `JETLS/live`  | Assignment in soft scope shadows a global variable |
| [`lowering/captured-boxed-variable`](@ref diagnostic/reference/lowering/captured-boxed-variable) | `Information`         | `JETLS/live`  | Variables captured by closures that require boxing |
| [`lowering/unused-argument`](@ref diagnostic/reference/lowering/unused-argument)                 | `Information`         | `JETLS/live`  | Function arguments that are never used             |
| [`lowering/unused-local`](@ref diagnostic/reference/lowering/unused-local)                       | `Information`         | `JETLS/live`  | Local variables that are never used                |
| [`lowering/unused-assignment`](@ref diagnostic/reference/lowering/unused-assignment)             | `Information`         | `JETLS/live`  | Assignments whose values are never read            |
| [`lowering/unused-import`](@ref diagnostic/reference/lowering/unused-import)                     | `Information`         | `JETLS/live`  | Imported names that are never used                 |
| [`lowering/unreachable-code`](@ref diagnostic/reference/lowering/unreachable-code)               | `Information`         | `JETLS/live`  | Code after a block terminator that is never reached  |
| [`lowering/unsorted-import-names`](@ref diagnostic/reference/lowering/unsorted-import-names)     | `Hint`                | `JETLS/live`  | Import/export names not sorted alphabetically      |
| [`toplevel/error`](@ref diagnostic/reference/toplevel/error)                                     | `Error`               | `JETLS/save`  | Errors during code loading                         |
| [`toplevel/method-overwrite`](@ref diagnostic/reference/toplevel/method-overwrite)               | `Warning`             | `JETLS/save`  | Method definitions that overwrite previous ones    |
| [`toplevel/abstract-field`](@ref diagnostic/reference/toplevel/abstract-field)                   | `Information`         | `JETLS/save`  | Struct fields with abstract types                  |
| [`inference/undef-global-var`](@ref diagnostic/reference/inference/undef-global-var)             | `Warning`             | `JETLS/save`  | References to undefined global variables           |
| [`inference/field-error`](@ref diagnostic/reference/inference/field-error)                       | `Warning`             | `JETLS/save`  | Access to non-existent struct fields               |
| [`inference/bounds-error`](@ref diagnostic/reference/inference/bounds-error)                     | `Warning`             | `JETLS/save`  | Out-of-bounds field access by index                |
| [`inference/method-error`](@ref diagnostic/reference/inference/method-error)                     | `Warning`             | `JETLS/save`  | No matching method found for function calls        |
| [`inference/non-boolean-cond`](@ref diagnostic/reference/inference/non-boolean-cond)             | `Warning`             | `JETLS/save`  | Non-boolean value used in boolean context          |
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

Examples:

```julia
macro lowering_error(x)
    $(x)  # `$` expression outside string or quote block (JETLS lowering/error)
end

function unresolved_goto()
    @label retry
    inner = () -> @goto retry  # label `retry` referenced but not defined (JETLS lowering/error)
    inner()                    # (`@goto` cannot cross function boundaries)
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

!!! note "Correlated condition analysis"
    The analysis recognizes correlated conditions: if a variable is assigned
    under a condition and later used under the same condition, no diagnostic
    is emitted. This works with simple variables, `&&` chains, and nested
    `if` blocks:
    ```julia
    function correlated(cond)
        if cond
            y = 42
        end
        if cond
            return sin(y)  # No diagnostic: analysis tracks that `cond`
                           # is the same in both branches
        end
    end
    ```
    This is limited to conditions that are simple local variables or `&&`
    chains of local variables (e.g. `if x && z`). Compound expressions
    like `if x > 0` are not tracked as correlated conditions.

!!! tip "Workaround: Using `@assert @isdefined` as a hint"
    There are cases where you know a variable is always defined at a
    certain point, but the analysis cannot prove it. This includes
    compound conditions (e.g. `if !isnothing(x)`), complex control flow, or
    general runtime invariants that the compiler cannot figure out
    statically. In such cases, you can use
    `@assert @isdefined(var) "..."` as a hint:
    ```julia
    function compound_condition(x)
        if !isnothing(x)
            y = sin(x)
        end
        if !isnothing(x)
            @assert @isdefined(y) "compiler hint"
            return cos(y)  # No diagnostic after the assertion
        end
    end
    ```
    This hint allows the compiler to avoid generating unnecessary
    `UndefVarError` handling code, and also serves as documentation
    that you've verified the variable is defined at this point.

!!! tip "Noreturn functions as guards"
    Calls to `throw`, `error`, `rethrow`, and `exit` are recognized
    as noreturn. If an else branch calls one of these, the analysis
    knows code after the branch can only be reached when the variable
    is defined:
    ```julia
    function guarded(x)
        if x > 0
            y = x
        else
            error("x must be positive")
        end
        return sin(y)  # No diagnostic: error() guarantees y is defined
    end
    ```
    See the [caveat on noreturn functions](@ref diagnostic/reference/lowering/unreachable-code)
    in the unreachable code section for limitations.

#### [Ambiguous soft scope (`lowering/ambiguous-soft-scope`)](@id diagnostic/reference/lowering/ambiguous-soft-scope)

**Default severity**: `Warning`

Reported when a variable is assigned inside a `for`, `while`, or
`try`/`catch` block at the top level of a file, and a global variable
with the same name already exists[^on_soft_scope]. This assignment is
ambiguous because it behaves differently depending on where the code
runs:
- In the REPL or notebooks: assigns to the existing global
- In a file: creates a new local variable, leaving the global
  unchanged

[^on_soft_scope]: See
    [On Soft Scope](https://docs.julialang.org/en/v1/manual/variables-and-scoping/#on-soft-scope)
    in the Julia manual.

Example ([A Common Confusion](https://docs.julialang.org/en/v1/manual/variables-and-scoping/#A-Common-Confusion-2479cb3548c466db) adapted from the Julia manual):

```@eval
using Markdown

mktemp() do file, io
    code = """
    # Print the numbers 1 through 5
    global i = 0
    while i < 5
        i += 1  # Assignment to `i` in soft scope is ambiguous (JETLS lowering/ambiguous-soft-scope)
                # Variable `i` may be used before it is defined (JETLS lowering/undef-local-var)
        println(i)
    end
    """
    write(io, code)
    close(io)
    err = IOBuffer()
    try
        run(pipeline(`$(Base.julia_cmd()) --startup-file=no --color=no $file`; stderr=err))
    catch
    end
    output = String(take!(err))
    lines = split(output, '\n')
    idx = findfirst(l -> startswith(l, "Stacktrace:"), lines)
    if idx !== nothing
        lines = lines[1:idx]
    end
    push!(lines, "...")
    output = join(lines, '\n')
    output = replace(output, file=>"ambiguous-scope.jl")

    Markdown.parse("""
    > `ambiguous-scope.jl`
    ``````julia
    $(code)
    ``````

    This diagnostic matches the warning that Julia itself emits at runtime.
    Running the example above as a file produces:
    > `julia ambiguous-scope.jl`
    ``````
    $(output)
    ``````
    """)
end
```

!!! note "Why is `lowering/undef-local-var` also reported?"
    Since `i += 1` desugars to `i = i + 1`, the new local `i` is read
    before being assigned, which also triggers
    [`lowering/undef-local-var`](@ref diagnostic/reference/lowering/undef-local-var)
    and causes the `UndefVarError` shown above at runtime.

!!! tip "Code actions available"
    Two quick fixes are offered: "Insert `global i` declaration" (preferred)
    to assign to the existing global, and "Insert `local i` declaration" to
    explicitly mark the variable as local and suppress the warning.

!!! note "Notebook mode"
    This diagnostic is suppressed for [notebooks](@ref notebook), where soft
    scope semantics are enabled (matching REPL behavior).

#### [Captured boxed variable (`lowering/captured-boxed-variable`)](@id diagnostic/reference/lowering/captured-boxed-variable)

**Default severity**: `Information`

Reported when a variable is captured by a closure and requires "boxing" due to
being assigned multiple times. Captured boxed variables are stored in heap-allocated
containers (a.k.a. `Core.Box`), which can cause type instability and hinder
compiler optimizations.[^performance_tip]

[^performance_tip]:
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

#### [Unused argument (`lowering/unused-argument`)](@id diagnostic/reference/lowering/unused-argument)

**Default severity**: `Information`

Function arguments that are declared but never used in the function body.
The argument is marked with the `Unnecessary` tag.[^unnecessary_tag]

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

Local variables that are never used anywhere in their scope. The
variable is marked with the `Unnecessary` tag.[^unnecessary_tag]

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

#### [Unused assignment (`lowering/unused-assignment`)](@id diagnostic/reference/lowering/unused-assignment)

**Default severity**: `Information`

Assignments to local variables whose values are never read. This
diagnostic targets individual assignments where the value is overwritten
or the function exits before the value is read. The assignment is
marked with the `Unnecessary` tag.[^unnecessary_tag]

This diagnostic does not overlap with
[`lowering/unused-local`](@ref diagnostic/reference/lowering/unused-local):
`unused-local` reports variables that are never used anywhere, while
`unused-assignment` reports specific assignments to variables that *are*
used elsewhere. For example:

```julia
function f(x::Bool)
    if x
        z = "Hi"
        println(z)  # z is used here, so `lowering/unused-local` is NOT reported
    end
    if x
        z = "Hey"   # but this assignment's value is never read → `lowering/lunused-assignment`
    end
end
```

Compare with a fully unused variable, which only triggers `unused-local`:

```julia
function g()
    y = 42  # y is never used anywhere → `lowering/unused-local`
end
```

!!! tip "Code action available"
    Two code actions are available for this diagnostic:
    - "Delete assignment" to remove only the left-hand side (keeping the
      right-hand side expression)
    - "Delete statement" to remove the entire assignment statement

!!! note "Closure-captured variables"
    Variables captured by closures are excluded from this analysis to
    avoid false positives, since the CFG cannot precisely model when
    closures are called.

#### [Unused import (`lowering/unused-import`)](@id diagnostic/reference/lowering/unused-import)

**Default severity**: `Information`

Reported when an explicitly imported name is never used within the same module
space. This diagnostic helps identify unnecessary imports that can be removed
to keep your code clean. The unused name is marked with the `Unnecessary`
tag.[^unnecessary_tag]

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

#### [Unused label (`lowering/unused-label`)](@id diagnostic/reference/lowering/unused-label)

**Default severity**: `Information`

Reported when a `@label` is declared but never referenced by any `@goto`
in the same function body. The label is marked with the `Unnecessary`
tag.[^unnecessary_tag]

Example:

```julia
function unused_label()
    @label spare  # Unused label `spare` (JETLS lowering/unused-label)
    return 1
end
```

Because `@goto` cannot cross function boundaries, a `@label` in an outer
function is also unused even when an inner closure references the same
name:

```julia
function outer()
    @label here  # Unused label `here` (JETLS lowering/unused-label)
    inner = () -> @goto here  # also reported as `lowering/error`
    inner()
end
```

!!! tip "Code action available"
    Use the "Remove unused label" code action to delete the `@label` statement.

#### [Unreachable code (`lowering/unreachable-code`)](@id diagnostic/reference/lowering/unreachable-code)

**Default severity**: `Information`

Reported when code appears after a statement that always exits the
current block, making subsequent code unreachable. The unreachable
code is marked with the `Unnecessary` tag.[^unnecessary_tag]

Example:

```julia
function after_return()
    return 1
    x = 2  # Unreachable code (JETLS lowering/unreachable-code)
    y = 3  # Also unreachable
end

function all_branches_return(x)
    if x > 0
        return 1
    else
        return -1
    end
    println("unreachable")  # Unreachable code (JETLS lowering/unreachable-code)
end

function after_continue()
    for i = 1:10
        continue
        println(i)  # Unreachable code (JETLS lowering/unreachable-code)
    end
end

function after_throw()
    throw(ErrorException("error"))
    cleanup()  # Unreachable code (JETLS lowering/unreachable-code)
end

function after_error()
    error("something went wrong")
    cleanup()  # Unreachable code (JETLS lowering/unreachable-code)
end

function after_rethrow()
    try
        do_something()
    catch
        rethrow()
        println("unreachable")  # Unreachable code (JETLS lowering/unreachable-code)
    end
end
```

!!! tip "Code action available"
    A "Delete unreachable code" quick fix is available that removes
    the unreachable region along with surrounding whitespace, from
    the end of the terminating statement to the end of the dead code.

!!! note "Caveat on noreturn functions"
    The analysis assumes that `error`, `rethrow`, and `exit` never return.
    If any loaded code adds an overload that returns normally, the analysis may
    produce incorrect results.
    Such overloading is extremely unlikely in practice, and this possibility is
    accepted as a trade-off for better diagnostics.

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
    types are inherently only known at compile time[^nospecialize_tip]),
    you can suppress this diagnostic using [pattern-based configuration](@ref config/diagnostic-patterns):
    ```toml
    [[diagnostic.patterns]]
    pattern = "`MyStruct` has abstract field `.*`"
    match_by = "message"
    match_type = "regex"
    severity = "off"
    ```

[^nospecialize_tip]: For such cases, you can add `@nospecialize` to the use-site methods to allow them to handle abstract data types while avoiding excessive compilation.

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
function undef_global_var(x)
    Base.Math.sinkernel(x)  # `Base.Math.sinkernel` is not defined (JETLS inference/undef-global-var)
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

#### [Method error (`inference/method-error`)](@id diagnostic/reference/inference/method-error)

**Default severity:** `Warning`

Function calls where no matching method can be found for the inferred argument
types. This diagnostic detects potential `MethodError`s that would occur at
runtime.

Examples:

```julia
function method_error_example()
    return sin(1, 2)  # no matching method found `sin(::Int64, ::Int64)` (JETLS inference/method-error)
end
```

When multiple union-split signatures fail to find matches, the diagnostic will
report all failed signatures:

```julia
only_int(x::Int) = 2x

function union_split_method_error(x::Union{Int,String})
    return only_int(x)  # no matching method found `only_int(::String)` (1/2 union split)
                        # (JETLS inference/method-error)
end
```

#### [Non-boolean condition (`inference/non-boolean-cond`)](@id diagnostic/reference/inference/non-boolean-cond)

**Default severity:** `Warning`

Non-boolean values used in boolean context, such as `if` or `while` conditions.
Julia requires conditions to be strictly `Bool`; using other types will raise a
`TypeError` at runtime.

Examples:

```julia
function non_boolean_example()
    x = 1
    if x  # non-boolean `Int64` found in boolean context
          # (JETLS inference/non-boolean-cond)
        return "truthy"
    end
end
```

When union-split types include non-boolean branches:

```julia
function find_zero(xs::Vector{Union{Missing,Int}})
    for i in eachindex(xs)
        xs[i] == 0 && return i  # non-boolean `Missing` found in boolean context (1/2 union split)
                                # (JETLS inference/non-boolean-cond)
    end
end
```

!!! tip "Common case: `Any`-typed arguments and `==`"
    When an argument is inferred as `Any`, `==` returns
    `Union{Bool,Missing}` (because `==(::Missing, ::Any)` is a
    candidate method):

    ```julia
    function check(x, y::AbstractString)
        x == :flag || error("x is invalid")  # non-boolean `Missing` found in boolean context (1/2 union split)
                                             # (JETLS inference/non-boolean-cond)
        return println(y)
    end
    ```

    You can resolve this by either:
    - Restricting the argument type so that `==` no longer returns
      `Missing` (e.g. `x::Symbol`).
    - Adding a `::Bool` return type annotation to the comparison
      expression if you know `x` will never be `missing`
      (e.g. `(x == :flag)::Bool`).

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
pattern = "lowering/(unused-argument|unused-local|unused-assignment)"
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
section in the [JETLS configuration](@ref config) page.


[^unnecessary_tag]: The `Unnecessary` [diagnostic tag](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#diagnosticTag)
    indicates that the marked code is unnecessary or unused, which
    causes editors to display it as faded/grayed out.
