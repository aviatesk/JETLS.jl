# CHANGELOG

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

> [!note]
> JETLS uses date-based versioning (`YYYY-MM-DD`) rather than semantic versioning,
> as it is not registered in General due to environment isolation requirements.
>
> Each dated section below corresponds to a release that can be installed via
> `Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="YYYY-MM-DD")`
>
> To install the latest version regardless of date, re-run the installation command:
> ```bash
> julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="release")'
> ```

## Unreleased

- Commit: [`HEAD`](https://github.com/aviatesk/JETLS.jl/commit/HEAD)
- Diff: [`0d67c12...HEAD`](https://github.com/aviatesk/JETLS.jl/compare/0d67c12...HEAD)

### Announcement

> [!important]
> JETLS requires Julia 1.12.2 or later.
> It does not support Julia 1.12.1 or earlier, nor Julia 1.13+/nightly.

> [!warning]
> JETLS currently has a known memory leak issue where memory usage grows with each re-analysis (https://github.com/aviatesk/JETLS.jl/issues/357).
> As a temporary workaround, you can disable full-analysis for specific files using the `analysis_overrides` [initialization option](https://aviatesk.github.io/JETLS.jl/release/launching/#init-options):
> ```jsonc
> // VSCode settings.json example
> {
>   "jetls-client.initializationOptions": {
>     "analysis_overrides": [
>       { "path": "src/**/*.jl" },
>       { "path": "test/**/*.jl" }
>     ]
>   }
> }
> ```
> This disables analysis for matched files. Basic features like completion still might work, but most LSP features will be unfunctional.
> Note that `analysis_overrides` is provided as a temporary workaround and may be removed or changed at any time. A proper fix is being worked on.

### Breaking

- `inference/non-boolean-cond` is now reported as [`inference/type-error/non-bool-cond`](https://aviatesk.github.io/JETLS.jl/release/diagnostic/#diagnostic/reference/inference/type-error/non-bool-cond). Existing diagnostic pattern configurations that match the old code continue to apply for now, but this compatibility support may be removed in a future release.

### Added

- Added the [`inference/type-error/type-assert`](https://aviatesk.github.io/JETLS.jl/release/diagnostic/#diagnostic/reference/inference/type-error/type-assert) diagnostic for type assertions that inference can prove will fail:
  ```julia
  let x = rand()
      x::Int  # TypeError: expected Int64, got Float64 (JETLS inference/type-error/type-assert)
  end
  ```

- Added detection of unsupported keyword arguments: a call that passes a keyword argument the called method does not accept is now reported under the [`inference/method-error`](https://aviatesk.github.io/JETLS.jl/release/diagnostic/#diagnostic/reference/inference/method-error) diagnostic:
  ```julia
  kwfunc(; kw1=nothing) = kw1
  kwfunc(; kw3=42)  # unsupported keyword argument `kw3` (JETLS inference/method-error)
  ```

- Added the [`inference/undef-keyword`](https://aviatesk.github.io/JETLS.jl/release/diagnostic/#diagnostic/reference/inference/undef-keyword) diagnostic: a call that omits a required keyword argument (one declared without a default), which raises `UndefKeywordError` at runtime, is now reported:
  ```julia
  required_keyword(pos; key) = (pos, key)
  required_keyword(42)  # missing keyword argument `key` (JETLS inference/undef-keyword)
  ```

- Added the [`inference/type-error/keyword`](https://aviatesk.github.io/JETLS.jl/release/diagnostic/#diagnostic/reference/inference/type-error/keyword) diagnostic: a call that passes a keyword argument whose value type does not match the keyword's declared type, which raises `TypeError` at runtime, is now reported:
  ```julia
  typed_keyword(; key::Int=0) = key
  typed_keyword(; key=1.0)  # TypeError: expected `Int64`, got `Float64` (JETLS inference/type-error/keyword)
  ```

### Changed

- `inference/*` diagnostic related information now labels inference frames as `origin`, `via`, or `entry`, making it clearer where the error originated and which analysis entry reported it.

- `inference/type-error/*` now groups diagnostics for the subset of runtime `TypeError` cases that JETLS can infer, including non-`Bool` conditions and statically failing type assertions. Users can ignore or reconfigure this family together with a regex code match such as `inference/type-error/.*`.

- Updated Compiler.jl API compatibility for the incoming Julia 1.12.7 release while retaining support for Julia pre-1.12.6 Compiler.jl APIs.

- Improved startup latency by precompiling the `initialize` request round-trip, so the first request is less likely to hit strict client `initialize` timeouts (such as Helix's 20-second default). On slower machines, raising the client-side timeout may still be needed. (xref: https://github.com/aviatesk/JETLS.jl/issues/784)

- Reworked the [diagnostics documentation](https://aviatesk.github.io/JETLS.jl/release/diagnostic/): a new [Analysis stages](https://aviatesk.github.io/JETLS.jl/release/diagnostic/#diagnostic/stage) section explains what produces each diagnostic category, which tool powers it, when it runs, and how the stages depend on one another. It also adds a [security caveat](https://aviatesk.github.io/JETLS.jl/release/diagnostic/#diagnostic/stage/toplevel) that full analysis loads and runs your code (so JETLS should not be run on untrusted code), and documents how each [`inference/*` diagnostic](https://aviatesk.github.io/JETLS.jl/release/diagnostic/#diagnostic/reference/inference) corresponds to the Julia runtime error it predicts.

### Fixed

- Fixed a false `lowering/unused-import` report for a name used only inside a `@static` condition or a branch not selected by the JETLS analysis process:
  ```julia
  using Base: VERSION
  @static if VERSION ≥ v"1.12"
      # `VERSION` is no longer misreported as an unused import
  end
  ```

- Document-highlight and rename now also cover identifiers used in `@static` branches not selected by the JETLS analysis process.

- Fixed false `lowering/unused-local`, `lowering/unused-argument`, and `lowering/unused-assignment` reports for a binding whose only use is in a `@static` branch not selected by the JETLS analysis process.

## 2026-06-26

- Commit: [`0d67c12`](https://github.com/aviatesk/JETLS.jl/commit/0d67c12)
- Diff: [`35c3262...0d67c12`](https://github.com/aviatesk/JETLS.jl/compare/35c3262...0d67c12)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-06-26")'
  ```

### Changed

- Updated JuliaSyntax.jl, JuliaLowering.jl, JET.jl and JuliaInterpreter.jl revisions, bringing in several lowering fixes and fixes for world-age-related analysis errors.

### Fixed

- Fixed `toplevel/error` diagnostics reporting `method too new to be called from this world context` when analyzing top-level `@eval` loops that generate methods. (Closed https://github.com/aviatesk/JETLS.jl/issues/341)

- Fixed hover on symbol literals such as `:foo` to show the literal expression (`:foo :: Symbol`) instead of the bare name with internal `Core.Const` details.

- Fixed stale methods from previous script or notebook analyses lingering after re-analysis or occasionally triggering `Method ... already disabled` cleanup errors.

- Fixed property completion (`obj.`) returning no suggestions in some contexts where the incomplete dot-access prevented type inference, such as inside `try`/`catch` blocks or on the right-hand side of an assignment (`out = obj.`).

## 2026-06-23

- Commit: [`35c3262`](https://github.com/aviatesk/JETLS.jl/commit/35c3262)
- Diff: [`d15f92f...35c3262`](https://github.com/aviatesk/JETLS.jl/compare/d15f92f...35c3262)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-06-23")'
  ```

### Fixed

- Fixed spurious `Any` type annotations caused by free static parameters left inside inferred method argument types, such as `Vector{T}` in `f(a::Vector{T}) where {T}`. (Closed https://github.com/aviatesk/JETLS.jl/issues/768)

- Fixed type annotation for script-mode files so inferred `const` globals use their actual type instead of an internal `JET.AbstractBindingState`, avoiding spurious annotations.

## 2026-06-20

- Commit: [`d15f92f`](https://github.com/aviatesk/JETLS.jl/commit/d15f92f)
- Diff: [`5643648...d15f92f`](https://github.com/aviatesk/JETLS.jl/compare/5643648...d15f92f)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-06-20")'
  ```

### Fixed

- Fixed false "not concretized" `toplevel/error` diagnostics on top-level `for` loops over `const` globals when the loop body contains a comprehension. (Fixed https://github.com/aviatesk/JETLS.jl/issues/555 via https://github.com/aviatesk/JET.jl/pull/830)

- Fixed type annotation for nested local closures that capture values already captured by an enclosing closure.

- Fixed type annotation results for methods whose signature contains static parameters such as `f(a::Vector{T}) where {T}` so reachable calls like `copy(a)` no longer collapse to `Union{}`. (Closed https://github.com/aviatesk/JETLS.jl/issues/764)

- Fixed the names introduced by `import`/`using`/`export`/`public` statements nested in a block (e.g. version-gated imports) not being recognized by document highlight, find references, rename, and semantic tokens.

## 2026-06-18

- Commit: [`5643648`](https://github.com/aviatesk/JETLS.jl/commit/5643648)
- Diff: [`a42a435...5643648`](https://github.com/aviatesk/JETLS.jl/compare/a42a435...5643648)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-06-18")'
  ```

### Added

- Added type inlay hints showing inferred types next to expressions (bindings, calls, function return types, branch results, etc.) so types are visible inline without hovering.
  Method bodies are inferred against their declared signature, and top-level chunks (e.g. standalone `let` blocks) are inferred independently.
  Hints are enabled by default; [`[inlay_hint.types] enabled`](https://aviatesk.github.io/JETLS.jl/release/configuration/#config/inlay_hint/types/enabled) toggles them.
  See the [Type hints](https://aviatesk.github.io/JETLS.jl/release/features/#features/inlay-hint/types) page for examples.

  <img width="976" height="637" alt="Inlay type hint demo" src="https://github.com/user-attachments/assets/baa2ff1b-df38-4304-a479-f2a2b4ba3e7b" />

- Added a macro expansion view that shows expanded macro code in a read-only document — served through the LSP 3.18 `workspace/textDocumentContent` request, or a temporary-file fallback for clients without that capability. It is triggered through code actions: one expands the macro call under the cursor, and one recursively expands every macro in the enclosing top-level form.
  See the [Macro expansion code view](https://aviatesk.github.io/JETLS.jl/release/features/#features/code-views/macro-expansion) page for details.

- Added a type annotation view that shows a top-level form with its inferred types applied as explicit `::T` annotations in a read-only document — served through the LSP 3.18 `workspace/textDocumentContent` request, or a temporary-file fallback for clients without that capability. It is triggered through a code action on the enclosing top-level form.
  See the [Type annotation code view](https://aviatesk.github.io/JETLS.jl/release/features/#features/code-views/type-annotations) page for details.

- Added [`lowering/inactive-code`](https://aviatesk.github.io/JETLS.jl/release/diagnostic/#diagnostic/reference/lowering/inactive-code) diagnostic that marks `@static` branches not taken in the current environment (e.g. a Windows-only branch when analyzing on macOS) at `Hint` severity with the `Unnecessary` tag, so editors gray out code that is excluded from analysis.

- Added [`lowering/unconstrained-static-parameter`](https://aviatesk.github.io/JETLS.jl/release/diagnostic/#diagnostic/reference/lowering/unconstrained-static-parameter) diagnostic that warns when a method declares a static parameter that does not appear in the type of any function parameter, so its value cannot be deduced when the method is called.
  This matches the warning Julia itself emits when evaluating such a method definition.
  For example:
  ```julia
  f(::T) where {T,S} = S  # Method definition declares type variable `S` but does not use it in the type of any function parameter
                          # (JETLS lowering/unconstrained-static-parameter)
  ```

- Added support for the LSP 3.18 `textDocument/rangesFormatting` request so clients that advertise `textDocument.rangeFormatting.rangesSupport` can format multiple ranges in a single request.

### Changed

- Improved type precision for local closures with untyped parameters (`do x`, `x -> ...`): their parameter types are now inferred from the argument types observed at the closure's call sites instead of degrading to `Any`, so hover, inlay hints and other type-aware features show precise types in closure bodies, in comprehensions, and for results of higher-order calls like `map`. Parameter annotations other than `::Any` are always respected as-is.

- Added hover and inlay hints for unannotated parameters of local closures, showing the parameter types inferred from the closure's call sites (e.g. `map(xs) do x::Int` for `xs::Vector{Int}`, or `f = x::Union{Float64, Int} -> 2x` when `f` is called with both `Float64` and `Int`).
  This covers all local-closure forms — arrow and `do`-block lambdas, anonymous and named local closures.
  Destructuring parameters are annotated per component (e.g. `do (key::String, val::Int)`), consistent with for-loop iteration variables.
  Parameters whose type cannot be narrowed beyond `Any` are left without a hint.

- Hover headers now include inferred lattice details as a Julia comment when the displayed type hides more precise information.

- JETLS now performs correct scope resolution on identifiers used inside `@static` macrocalls, which previously could yield incorrect results in edge cases.
  Invalid `@static` usage (an unsupported expression shape, or a condition that fails to evaluate to a `Bool`) is now reported in place as `lowering/macro-expansion-error` while the code still flows through to analysis.

- The `"JuliaFormatter"` preset now supports `textDocument/rangeFormatting` and `textDocument/rangesFormatting`, which previously failed with a "JuliaFormatter does not support range formatting" error. This requires [JuliaFormatter v2.7.0](https://github.com/JuliaEditorSupport/JuliaFormatter.jl/releases/tag/v2.7.0) or later. See [the formatter integration docs](https://aviatesk.github.io/JETLS.jl/release/formatting/#formatting/prerequisites) for setup.

- Allows scope resolution for identifiers inside `@lock` blocks so language features distinguish bindings introduced in the protected body from surrounding bindings.

- Signature help now uses LSP 3.18 `activeParameter: null` for clients that support it, so editors can avoid highlighting a stale parameter after all known keywords have already been filled.

- Changed TestRunner log viewing to use readonly virtual documents when supported, and cleanup-enabled temporary files otherwise, avoiding empty `untitled:` log tabs and mismatched log file paths.

### Fixed

- Fixed language feature registrations so JETLS only targets supported Julia documents — saved files (`file:`), unsaved buffers (`untitled:` and `buffer:`), and notebook cells — while still keeping virtual documents from unsupported schemes (e.g. `jetls:`) from triggering diagnostics, code actions, and other file-backed features.

- Fixed language feature requests for unsupported document URIs (e.g. virtual documents, or any request from clients that ignore the registered document selectors) blocking for up to 10 seconds before returning an empty result; such requests now return immediately.

- Fixed `diagnostic.patterns` order handling so declaration order is preserved after configuration merging. When multiple matching rules have the same priority, later rules now override earlier rules.

- Fixed type information collapsing to `Any` inside closures defined in functions that have default positional arguments or keyword arguments. Hover, inlay hints and other type-aware features now show precise types for such closure bodies and their captured variables.

- Fixed renaming symbols inside Jupyter notebook cells on VS Code, which previously failed with a "The rename edit returned from the server is not valid anymore and cannot be applied." error.

- Fixed dot completion erroring (or offering nothing) when the prefix sits in code that inference proves unreachable, such as code after a non-returning call. Module and global-const prefixes such as `Base.` now resolve their members there as usual.

- Fixed hover on unannotated local closure parameters showing `Core.OpaqueClosure` internals instead of the inferred argument type.

- Fixed hover and other type-aware features inside local closure bodies losing constant-propagated details for captured values.

- Fixed false positive `lowering/undef-local-var` diagnostics for variables guarded by negated `@isdefined` conditions, including `&&` and `||` combinations where definedness is guaranteed.

- Fixed false positive `lowering/unused-assignment` diagnostics on phantom `struct` type parameters such as `struct MyVal{T} end`.

## 2026-06-03

- Commit: [`a42a435`](https://github.com/aviatesk/JETLS.jl/commit/a42a435)
- Diff: [`0b038c7...a42a435`](https://github.com/aviatesk/JETLS.jl/compare/0b038c7...a42a435)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-06-03")'
  ```

### Removed

- Removed the legacy `inlay_hint.block_end_min_lines` configuration alias. Use `inlay_hint.block_end.min_lines` instead.

- Removed support for the legacy `completion.method_signature.prepend_inference_result` configuration key.
  Inferred return types are now always shown in completion details and method signature documentation.

### Changed

- Updated JuliaSyntax.jl and JuliaLowering.jl dependency versions to latest.

- Improved responsiveness for repeated requests against the same document version. After an edit, follow-up LSP features such as diagnostics, document highlights, code actions, hover, definition etc. now reuse the current file's prepared syntax tree instead of rebuilding it for each request.

- Improved performance of type-aware features on open files. Repeated hover, definition, declaration and type definition requests in the same top-level expression can now reuse prior analysis results instead of rerunning inference each time.

- Improved unused-variable diagnostic message for assignments returned from tail position.
  For both `lowering/unused-local` and `lowering/unused-assignment`, JETLS now explains when Julia is implicitly returning the assignment expression's value, suggests `return name` when the binding itself should be returned, and offers an "Insert explicit return" quick fix for simple tail assignments. (Closed https://github.com/aviatesk/JETLS.jl/issues/723)

### Fixed

- Fixed false `lowering/unused-argument` reports — and missed argument occurrences for find-references / document-highlight / rename — on `@generated` functions nested inside another construct (e.g. as an inner constructor in a `struct` body). (Closed https://github.com/aviatesk/JETLS.jl/issues/722)

## 2026-05-27

- Commit: [`0b038c7`](https://github.com/aviatesk/JETLS.jl/commit/0b038c7)
- Diff: [`72cc49c...0b038c7`](https://github.com/aviatesk/JETLS.jl/compare/72cc49c...0b038c7)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-05-27")'
  ```

### Added

- Added support for "Go to Type Definition" (`textDocument/typeDefinition`).
  Invoking it on an expression jumps to the definition of its inferred type — e.g. landing on a binding of type `Foo` jumps to the `struct Foo` definition.
  For `Union` types the response includes one location per constituent.
  (https://github.com/aviatesk/JETLS.jl/pull/686)

  <img width="1333" height="571" alt="type definition demo" src="https://github.com/user-attachments/assets/b469f0d7-73ba-47aa-86e5-7861535459fd" />

- Added property completion (`x.│` / `x.partial│`). Typing `.` after a typed expression now offers the properties that `propertynames(::T)` reports for the dot prefix's inferred type — both plain struct fields and types with a custom `propertynames` overload are handled uniformly.
  Each candidate's inferred property type (`x.field :: T`) is resolved lazily, only when the client requests details for a focused item. The resolved documentation also includes the per-field docstring attached to that field in its struct definition, when present.
  For union-typed prefixes the offered names are the union of each component's `propertynames`, so the common `Union{T, Nothing}` pattern still surfaces `T`'s properties even though `propertynames(::Nothing) == ()`; type details merge each component's per-property type at resolve time.

  https://github.com/user-attachments/assets/3f2887b4-4c1c-41f9-b091-4eea2b6128bc

### Changed

- `textDocument/hover` now surfaces inferred types alongside documentation.
  Any identifier, dot expression, call result, or indexing position can be queried — `func(x) :: Int`, `s[2] :: Float64`, `Base.Pair :: typeof(Pair)`, etc. — and the type is queried at the cursor's byte range so flow-sensitive type narrowing is reflected.
  Binding hovers additionally carry a kind tag — `(argument)`, `(local)`, `(static parameter)`, or `(global)` — before the name, making the binding's role in scope visible.
  Closures display as function-arrow signatures like `(x::Int, y::Int) -> Int`, with argument names recovered from the body when available.
  Documentation is gathered both from the binding's own docstring and from the docstring of whatever value the expression resolves to via type inference. So e.g. given `sv = Some(sin)`, hovering on `sv.value` shows `sin`'s docstring even though `sin` doesn't appear at the cursor. For dot expressions whose LHS is a struct instance (`x.y│`), the per-field docstring attached to `y` in its struct definition is also surfaced when present.
  When the cursor is on the callee identifier (e.g. `sin│(rand(Int))`, `Base.Math.sin│(x)`), the header is promoted to the full call expression (`sin(rand(Int)) :: Float64`) and the docstring is narrowed to the dispatched method's doc when dispatch resolves to a single method (`sin(::Real)`). When the cursor sits past a call-like surface's closing punctuation (`f(args)│`, `xs[i]│`, `[a, b]│`, …), only the `expr :: T` header is shown without any docstring body. Non-call cursors (`f│`) still show every overload's doc.
  (https://github.com/aviatesk/JETLS.jl/pull/687)

  | Hover on call    | <img width="1086" height="418" alt="Hover on call demo" src="https://github.com/user-attachments/assets/cf3d2eb8-3036-44e2-b075-b3c9ca09dc35" />    |
  | ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
  | Hover on closure | <img width="1086" height="418" alt="Hover on closure demo" src="https://github.com/user-attachments/assets/285de208-a704-4978-9a89-829654f561bc" /> |

- `textDocument/definition` on a call site (`f(arg)│` or `f│(arg)`) now narrows to the method dispatch picked for the inferred argument types — e.g. `sin│(42)` jumps to `sin(::Real)` only, not to every method of `sin`. Bare cursors on the function name (`sin│`) still return all definitions.

- `textDocument/signatureHelp` and method-signature completion (`textDocument/completion`) now narrow overloads using the inferred type of each argument at the call site, including arbitrary local-scope expressions.
  Previously only top-level globals and literal arguments contributed to filtering, so `let x = rand(); sin(x,│); end` showed every `sin` method;
  with the local `x :: Float64` now folded in, only `sin(::T) where T<:Union{Float32, Float64}` is offered.

- `textDocument/semanticTokens` now classifies type parameters declared in `struct` / `abstract type` / `primitive type` headers (and their use sites inside the type body) as `typeParameter`. Previously these identifiers were classified as plain `variable`.

- `lowering/undef-global-var` now suppresses reports as soon as a sibling file in the same analysis unit defines the referenced name. Previously, adding `foo = ...` to one file left `foo` references in other files of the same unit flagged as undefined until the next full-analysis cycle (typically triggered on save) caught up.

- `lowering/macro-expansion-error` no longer aborts analysis of the enclosing top-level form. Any misuse JETLS's stubs for `Base` macros detect — invalid threadpool literal in `Threads.@spawn`, duplicate kwarg in `@info`/`@warn`/…, `@test` with `skip` + `broken`, wrong argument count in `@assert`/`@invoke`/`@kwdef`/`@assume_effects`/…, non-call shape passed to `@invoke`, malformed `@testset` body, and so on — is now reported in place while the macrocall body still flows through to scope and type analysis.
  Previously any of these would propagate a `MacroExpansionError`, remove the entire macrocall from analysis, and take every other LSP feature requiring full lowering of the enclosing function (hover, inlay, signature help, undef-var, references, …) down with it.
  Reports come with `Error` severity when Base would reject the misuse and `Warning` severity when Base accepts it silently or only deprecates.

- Documenter admonitions (`!!! note`, `!!! tip`, `!!! warning`, `!!! danger`, `!!! info`, `!!! compat`) in docstrings now render as Markdown blockquotes with a category-emoji header (e.g. `> **💡 Tip**`) wherever JETLS surfaces docstrings (hover, completion documentation, signature help).
  Previously the `!!!` block leaked through verbatim, leaving the editor's Markdown view to render it in unintended ways.

- Hover and method-signature completion documentation no longer surface Base's "No documentation found for ..." placeholder paragraph for bindings that exist but carry no docstring. The auto-generated method / type summary that follows the placeholder is still shown, so the hover stays informative without the placeholder noise.

### Fixed

- Fixed spurious diagnostics like `` `{ }` outside of `where` is reserved for future use `` falsely appearing on Jupyter notebook (`.ipynb`) files in VS Code. (Fixed https://github.com/aviatesk/JETLS.jl/issues/703)

- Fixed `jetls check` failing with "could not find any files to analyze" on Windows when the current working directory's drive letter casing differed from the URI-normalized form (Closed https://github.com/aviatesk/JETLS.jl/issues/679).

- `jetls check` no longer rejects files outside the current working directory. Previously, paths such as `jetls check ../foo.jl` were classified as out-of-scope by the LSP-style workspace boundary guard and produced "could not find any files to analyze". The CLI now analyzes any file passed on the command line regardless of where it lives relative to the cwd.

- `jetls check` now reports parse errors. Previously, files with syntax errors (e.g. an unclosed parenthesis like `f(x) = println(x`) silently produced "No diagnostics found".

- Fixed spurious `WARNING: Detected access to binding ... in a world prior to its definition world` messages emitted by `jetls check` and other server analyses.

- Identifiers interpolated into docstrings (e.g. `$(TYPEDEF)` / `$(TYPEDSIGNATURES)` from [DocStringExtensions.jl](https://github.com/JuliaDocs/DocStringExtensions.jl)) are now treated as real references during scope resolution. As a result, `lowering/unused-import` no longer falsely reports imports that are only used through docstring interpolations, and `lowering/undef-global-var` flags interpolations of names that aren't actually in scope. Other LSP features (hover, go-to-definition, find-references, …) also work on identifiers inside docstring interpolations. (Fixed https://github.com/aviatesk/JETLS.jl/issues/699)

- Identifiers inside keyword arguments of `@test`, `@test_broken`, and `@test_skip` (e.g. `flag` in `@test x broken=flag`) are now picked up by scope resolution, so undef-var diagnostics and find-references work for them. Previously the keyword arguments were dropped during macro expansion.

- Identifiers inside `@show`, `@debug`, `@info`, `@warn`, `@error`, and `@logmsg` calls — including kwarg values (e.g. `flag` in `@info "msg" extra=flag`) and splatted operands (e.g. `kws` in `@info "msg" kws...`) — are now picked up by scope resolution, so undef-var diagnostics and find-references work for them. Previously the identifiers in these macros were silently ignored. For the logging macros, duplicate kwarg names also surface as `lowering/macro-expansion-error` anchored at the call site.

- Fixed completion items to honor the client's `completionItem.resolveSupport.properties` capability. Previously, properties such as `kind` and `labelDetails` were updated during `completionItem/resolve` regardless of whether the client advertised lazy support for them, which caused visible glitches in some clients (e.g. flickering completion lists in [cmp-nvim-lsp](https://github.com/hrsh7th/cmp-nvim-lsp)). (Closed https://github.com/aviatesk/JETLS.jl/issues/711)

## 2026-05-08

- Commit: [`72cc49c`](https://github.com/aviatesk/JETLS.jl/commit/72cc49c)
- Diff: [`732c537...72cc49c`](https://github.com/aviatesk/JETLS.jl/compare/732c537...72cc49c)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-05-08")'
  ```

### Fixed

- JETLS now performs correct scope resolution on identifiers used inside Test.jl macro calls (i.e., `@testset`, `@test`, `@test_throws`, `@test_broken`, `@test_skip`, `@test_warn`, `@test_nowarn`, `@test_logs`, `@test_deprecated`, and `@inferred`), which previously could yield incorrect results in edge cases.

- Fixed pull-model diagnostics (`textDocument/diagnostic` and `workspace/diagnostic`) to refresh after `[diagnostic]` configuration changes. Previously, changing settings such as `diagnostic.enabled`, `diagnostic.allow_unused_underscore`, or `diagnostic.patterns` did not invalidate the client's cached results, so stale diagnostics remained until the file was edited.

### Changed

- Configuration parse errors now point at the offending key with its full dotted path, e.g. ```Invalid value at `diagnostic.allow_unused_underscore`: expected Bool, got String``` for type mismatches and ```Configuration file at … contains an unknown key: \`diagnostic.unknown_field\` ``` for unrecognized keys. Previously these messages either omitted the location entirely or referenced only the immediate key.

- Dropped the dependency on Configurations.jl. Configuration parsing and validation are now handled in-tree, so JETLS pulls in fewer transitive packages on first install and load.

## 2026-05-06

- Commit: [`732c537`](https://github.com/aviatesk/JETLS.jl/commit/732c537)
- Diff: [`563fd7e...732c537`](https://github.com/aviatesk/JETLS.jl/compare/563fd7e...732c537)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-05-06")'
  ```

### Changed

- Block-end inlay hints now display as `#= … =#` block comments (e.g. `end #= module Foo =#`), so what's shown matches the text inserted when the hint is applied.

- `textDocument/diagnostic` now returns an unchanged report when neither the document nor its analysis-unit siblings have changed since the previous pull, skipping diagnostic recomputation. This reduces redundant work on clients that aggressively re-pull diagnostics across all open files on each edit (e.g., Zed).

- Test runner code lens / code action now runs against the current editor buffer rather than the saved file. JETLS pipes the live buffer to the `testrunner` subprocess over stdin, so unsaved edits (including brand-new `@testset` / `@test` cases) execute as-is and the previous "Save the file first to run tests" error no longer occurs.
  The integration also works for buffers (`untitled:` for VSCode / `buffer:` for Sublime Text) that have never been saved to disk: relative `include` calls in the buffer resolve from the workspace root.
  This requires upgrading the `testrunner` CLI to a version that understands the `--read-stdin` flag. Reinstall the latest release with:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/TestRunner.jl", rev="release")'
  ```
  and confirm the upgrade by running `testrunner --help` and checking that `--read-stdin` appears under `Options:`.

### Fixed

- `lowering/unused-assignment` no longer flags an assignment in a `try` (or `catch`) body as dead when the assigned variable is read in the enclosing `finally`, even if the assignment is followed by `return`. The `finally` block runs before the return takes effect, so the value is live.
  ```julia
  function f()
      local x::Float64
      try
          y = sin(rand((rand(), Inf)))
          x = y               # previously: dead store
          return 0
      catch
          x = 0.0             # previously: dead store
          return 1
      finally
          push!(xs, x)
      end
  end
  ```

- `lowering/unused-assignment` no longer flags intermediate assignments in a `try` body when a later statement might throw.
  Common state-tracking idioms like the following now keep `state = "step1 starting"` and `state = "step2 starting"` live with respect to `log(state)`:
  ```julia
  function process()
      state = "init"
      try
          state = "step1 starting"  # previously: dead store
          step1()
          state = "step2 starting"  # previously: dead store
          step2()
          state = "done"
      finally
          log(state)
      end
  end
  ```

## 2026-05-05

- Commit: [`563fd7e`](https://github.com/aviatesk/JETLS.jl/commit/563fd7e)
- Diff: [`28972ef...563fd7e`](https://github.com/aviatesk/JETLS.jl/compare/28972ef...563fd7e)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-05-05")'
  ```

### Added

- Added [`textDocument/semanticTokens`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_semanticTokens) support.
  JETLS now emits `parameter`, `typeParameter`, and `variable` token types (with `declaration` / `definition` modifiers) so that themes can distinguish function arguments, type parameters, and local variables from generic identifiers. Global identifiers are also reported under a custom `jetls.unspecified` token type, which leaves the editor's syntactic color intact while still letting themes apply modifier styling to declaration/definition sites.
  Both full and range requests are supported.
  Because JETLS only emits identifier classifications and relies on the editor's syntactic highlighter for everything else, semantic tokens are only registered when the client advertises [`augmentsSyntaxTokens = true`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#semanticTokensClientCapabilities).
  See <https://aviatesk.github.io/JETLS.jl/release/features/#features/semantic-tokens> for details.

  <img width="969" height="343" alt="semantic tokens demo" src="https://github.com/user-attachments/assets/93f92c5a-2de2-499f-a87f-7dfcfec5d0b0" />

### Changed

- Significantly reduced latency on large files across most LSP features (hover, completion, diagnostics, inlay hint, code lens, …). For example, code lens generation on a file with 1000 `@testset` blocks dropped from ~590ms to ~1.4ms.

### Fixed

- Fixed `textDocument/inlayHint` for notebook cells, which previously misplaced hints (or rendered none at all) by treating the requested viewport and emitted hint positions as notebook-global coordinates rather than cell-local.

## 2026-05-02

- Commit: [`28972ef`](https://github.com/aviatesk/JETLS.jl/commit/28972ef)
- Diff: [`e784de8...28972ef`](https://github.com/aviatesk/JETLS.jl/compare/e784de8...28972ef)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-05-02")'
  ```

### Added

- `lowering/error` now reports `@goto` references that don't resolve to any `@label` in the same function body.
  For example:
  ```julia
  function f()
      @goto nonexist  # label `nonexist` referenced but not defined (JETLS lowering/error)
      println("foo")
  end
  ```

- Added the `lowering/unused-label` diagnostic, reported when a `@label` is declared but never referenced by any `@goto` in the same function body. The label is marked with the `Unnecessary` tag, so editors typically display it as faded/grayed out. A "Remove unused label" code action is also offered to drop the entire `@label` statement.
  For example:
  ```julia
  function f()
      @label spare  # Unused label `spare` (JETLS lowering/unused-label)
      return 1
  end
  ```

### Changed

- The reference count code lens is no longer shown for inner constructors of a `struct`.

- Updated JuliaSyntax.jl and JuliaLowering.jl dependency versions to latest, improving the performance of lowering-based LSP features (https://github.com/JuliaLang/julia/pull/61597).

### Fixed

- `lowering/unreachable-code` now uses control-flow reachability instead of syntactic block-walking, fixing several false positives and missed cases:
  - Code reachable via `@goto` nested inside an expression (e.g. `return cnd ? @goto(fallback) : println("Return"); @label fallback; ...`) is no longer reported as unreachable.
  - Code after `try ... finally ... end` whose `try` body always terminates is now correctly flagged as unreachable.

- Fixed `lowering/captured-box` related-information ("Captured by closure") highlighting the entire enclosing macrocall (e.g. a whole `@testset begin ... end` block) instead of the captured identifier when the captured reference lived inside a macro expansion.

- Fixed an "Unsupported URI" error that could occur when an unsaved (`untitled:`) buffer was edited and then closed in quick succession. Closing an unsaved buffer now also clears any analysis state associated with it, so previously analyzed top-level overloads no longer linger as ghost entries in completions or signature help.

- Fixed `textDocument/documentHighlight`, `textDoscument/references`, and `textDocument/rename` incorrectly treating same-named local arguments in disjoint scopes (e.g. two separate `do h ... end` blocks within the same `let` or function body) as the same binding.

- Fixed unused positional arguments with a default value (e.g. `bar` in `function f(x, bar="bar")`) being incorrectly treated as keyword arguments, suppressing the `"Prefix with '_' to indicate intentionally unused"` code action and skipping the unused-argument warning when the default's type annotation referenced a `where`-clause static parameter.

## 2026-04-28

- Commit: [`e784de8`](https://github.com/aviatesk/JETLS.jl/commit/e784de8)
- Diff: [`d1ebbb2...e784de8`](https://github.com/aviatesk/JETLS.jl/compare/d1ebbb2...e784de8)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-04-28")'
  ```

### Breaking

- Clients that previously handled the JETLS-defined `jetls.showReferences` command should switch to handling `editor.action.showReferences` instead. The new arguments are `[uriString, position, locations]`, where `locations` is the pre-resolved LSP `Location[]`, so clients no longer need to issue a `textDocument/references` request themselves. See the [Neovim setup section](https://aviatesk.github.io/JETLS.jl/release/#index/editor-setup/neovim) for an example handler.

### Added

- Added a [Features](https://aviatesk.github.io/JETLS.jl/release/features/) overview page to the documentation, providing a visual showcase of every LSP feature JETLS provides.

- Added `textDocument/declaration` ("go to declaration"). It jumps to the import site on an imported name (e.g. `using Base: sin`) and to the `local` line on a `local` declaration. When the symbol has no dedicated declaration site, the request falls back to the same logic as `textDocument/definition`.

- Added `textDocument/documentLink` support for `include("path")` and `include_dependency("path")` calls. The path string becomes a clickable link that opens the referenced file. Only non-interpolated string arguments whose path resolves to an existing file (relative to the current file's directory) are surfaced.

### Changed

- The [reference-count code lens](https://aviatesk.github.io/JETLS.jl/release/features/#features/code-lens/references) now emits `editor.action.showReferences` (a VSCode convention command) directly, instead of the JETLS-defined `jetls.showReferences`. Editors that follow the VSCode convention (e.g. Zed) now dispatch the lens out of the box; editors that do not (e.g. Neovim) need to register a client-side handler.

- When a reference-count code lens is clicked on a file whose full analysis has not yet run, a warning notification (via `window/showMessage`) is now shown instead of an empty references peek.

- The reference-count code lens is no longer shown on closures and inner functions defined inside another function body (e.g. `f = x -> ...`, nested `function`s).

- Diagnostic messages are now sent as `MarkupContent` when the client advertises the [`textDocument.diagnostic.markupMessageSupport`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#diagnosticClientCapabilities) capability (LSP 3.18), so Markdown formatting such as inline code renders properly in supporting clients (e.g. recent Sublime LSP). (https://github.com/aviatesk/JETLS.jl/pull/633)

### Fixed

- Fixed `textDocument/references` so that `includeDeclaration=false` now correctly excludes method definitions and declarations of the target binding. As a side benefit, the [reference-count code lens](https://aviatesk.github.io/JETLS.jl/release/features/#features/code-lens/references) now reports accurate counts.

- Fixed the reference-count code lens, `textDocument/references`, `textDocument/documentHighlight`, and `textDocument/rename` silently dropping results after a full analysis completes.

- Names listed in `export` and `public` statements are now treated as references to the surrounding module's global bindings, so `textDocument/documentHighlight`, `textDocument/references`, `textDocument/definition`, and `textDocument/rename` all work when the cursor is placed on an exported/public name.

- Locally-introduced names from `import`/`using` statements are now treated as local declarations. This covers every binding form, including `using A` / `import A`, `using A, B`, dotted paths (`using A.B`), relative paths (`using .Inner`), and explicit names (`using A: x, y` / `using A: x as y`).

- `textDocument/rename` on imported names now preserves the source-module name by introducing or updating an `as` alias. For example, renaming `sin` in `using Base: sin` produces `using Base: sin as newsin` plus `newsin` at use sites. Renaming an alias back to its source name drops the ` as …` suffix. In forms where Julia does not accept `as` (`using M`, `using M, N`, `using M.Sub`), rename falls back to a bare replacement.

- Fixed `textDocument/references`, `textDocument/documentHighlight`, `textDocument/definition`, `textDocument/declaration`, and `textDocument/rename` silently returning no results inside top-level definitions that combine a compound-assignment operator with a macro call (e.g. `x += @elapsed foo()`).

- By providing new-style macro definitions for JuliaLowering, LSP features (`textDocument/references`, `textDocument/rename`, `textDocument/documentHighlight`, `textDocument/definition`, `textDocument/declaration`) and diagnostics (`lowering/undef-global-var`, `lowering/unused-assignment`) now perform correct scope resolution on identifiers used inside `@__FUNCTION__`, `@ccall`, `@cfunction`, `@goto`, `@isdefined`, `@locals`, `@label`, and `Threads.@spawn` macrocalls, which previously could yield incorrect results in edge cases.

- Fixed false-positive `lowering/unused-assignment` reports for the assign-then-`@goto`-to-`@label` pattern, where the goto edge from `@goto done` to `@label done` was not modeled in the CFG so assignments before the `@goto` were incorrectly treated as overwritten by assignments after the `@label`.
  For example:
  ```julia
  function f(cond)
      local reports
      if cond
          reports = compute_cached()
          @goto done
      end
      reports = compute_default()
      @label done
      use(reports)
  end
  ```

- Fixed `lowering/unused-import` going stale in `workspace/diagnostic` when an explicit import in one file is consumed (or stops being consumed) by a sibling file in the same analysis unit. Closed files now refresh the diagnostic when a sibling edit could affect it.

- Fixed `textDocument/documentSymbol` and the reference-count code lens on the Jupyter notebook view in VSCode.

## 2026-04-14

- Commit: [`d1ebbb2`](https://github.com/aviatesk/JETLS.jl/commit/d1ebbb2)
- Diff: [`c954d83...d1ebbb2`](https://github.com/aviatesk/JETLS.jl/compare/c954d83...d1ebbb2)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-04-14")'
  ```

### Added

- Added [`inference/non-boolean-cond`](https://aviatesk.github.io/JETLS.jl/release/diagnostic/#diagnostic/reference/inference/non-boolean-cond) diagnostic that detects non-boolean values used in boolean context (e.g. `if`, `while`, ternary `?:`, `&&`, `||`).
  ```julia
  function find_zero(xs::Vector{Union{Missing,Int}})
      for i in eachindex(xs)
          xs[i] == 0 && return i  # non-boolean `Missing` found in boolean context
      end
  end
  ```

### Changed

- The release script now sets `Project.toml` version to `YYYY.MM.DD` (converted from the `YYYY-MM-DD` release date), so `pkg> app status` displays a meaningful version (https://github.com/aviatesk/JETLS.jl/issues/629).

- Updated JuliaSyntax.jl and JuliaLowering.jl dependencies.

### Fixed

- Unreachable code after assignment with noreturn RHS (e.g. `y = error(x)`) is now correctly detected.

- Fixed errors when opening unsaved buffers in Sublime Text, which uses the `buffer:` URI scheme instead of VSCode's `untitled:` scheme convention (https://github.com/aviatesk/JETLS.jl/issues/626).

- Fixed false "macro name not found" diagnostics on macros like `@enumx` that internally generate baremodules
  (Closed https://github.com/aviatesk/JETLS.jl/issues/628).

## 2026-04-06

- Commit: [`c954d83`](https://github.com/aviatesk/JETLS.jl/commit/c954d83)
- Diff: [`8deefa8...c954d83`](https://github.com/aviatesk/JETLS.jl/compare/8deefa8...c954d83)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-04-06")'
  ```

### Added

- Extended noreturn optimization to recognize `error`, `rethrow`, and `exit` in addition to `throw`. These calls are now treated as block terminators for unreachable code detection and undef variable analysis, reducing false positives when these functions are used as guards. For example, the following code no longer produces a false "possibly undefined" warning on `y`:
  ```julia
  function f(x)
      if x > 0
          y = x
      else
          error("x must be positive")
      end
      return sin(y)  # no warning: error() guarantees y is defined
  end
  ```

- Noreturn detection now works for nested calls (e.g. `println(error(x))`) where a noreturn function appears in argument position.

### Changed

- Updated JuliaSyntax.jl and JuliaLowering.jl dependency versions to latest.

### Fixed

- Fixed scope resolution for notebook cells to use soft scope semantics, so that assignments inside loops correctly resolve to existing globals instead of creating ambiguous locals.

- Fixed a crash during signature analysis (`AssertionError: invalid cache_argtypes`) that occurred when constant propagation encountered methods using `@nospecializeinfer` with varying varargs arities.
  Updated the bundled `Compiler.jl` revision with the upstream fix (https://github.com/JuliaLang/julia#61502) (Closed https://github.com/aviatesk/JETLS.jl/issues/618).

## 2026-04-04

- Commit: [`8deefa8`](https://github.com/aviatesk/JETLS.jl/commit/8deefa8)
- Diff: [`d14efce...8deefa8`](https://github.com/aviatesk/JETLS.jl/compare/d14efce...8deefa8)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-04-04")'
  ```

### Added

- Added [`lowering/unreachable-code`](https://aviatesk.github.io/JETLS.jl/release/diagnostic/#diagnostic/reference/lowering/unreachable-code) diagnostic that detects code after block terminators (`return`, `throw`, `break`, `continue`), including cases where all branches of `if`/`elseif`/`else` or `try`/`catch` contain a terminator.
  Unreachable code is displayed as faded/grayed out with the `Unnecessary` tag.
  A "Delete unreachable code" quick fix code action is also available.

- Added [`lowering/ambiguous-soft-scope`](https://aviatesk.github.io/JETLS.jl/release/diagnostic/#diagnostic/reference/lowering/ambiguous-soft-scope) diagnostic that warns when a variable assignment inside a `for`/`while`/`try` block at the top level shadows an existing global variable.
  This matches the warning Julia itself emits at runtime for this pattern.
  Two code actions are offered: "Insert `global` declaration" (preferred) and "Insert `local` declaration".
  This diagnostic is suppressed for notebook cells, where soft scope semantics are enabled.

### Changed

- [`lowering/undef-local-var`](https://aviatesk.github.io/JETLS.jl/release/diagnostic/#diagnostic/reference/lowering/undef-local-var) now recognizes correlated conditions to reduce false positives.
  When a variable is assigned under a condition (e.g. `if x; y = 42; end`) and later used under the same condition (`if x; println(y); end`), the diagnostic is no longer emitted.
  This also works with `&&` chains (`if x && z`), nested `if` blocks that are equivalent to `&&`, and combinations of both.

- Updated JuliaSyntax.jl and JuliaLowering.jl dependency versions to latest.
  The updated JuliaLowering pipeline is faster overall (https://github.com/JuliaLang/julia/pull/61425), improving performance of LSP features that rely on lowering such as diagnostics and document highlight.

- The JETLS's own def-use analysis (`analyze_def_use_all_lambdas`) is now ~5x faster (684ms → 127ms).
  Combined with the JuliaSyntax/JuliaLowering pipeline improvements above, the overall analysis pipeline time is reduced by ~2x (3649ms → 1772ms) on a large file ([`test/test_lowering_diagnostic.jl`](https://github.com/aviatesk/JETLS.jl/blob/f893ccfe/test/test_lowering_diagnostic.jl), ~1600 lines) (https://github.com/aviatesk/JETLS.jl/pull/612).

- The "Prefix with `_`" code action is no longer offered for unused keyword arguments, since renaming a keyword argument changes the function's calling convention.

### Fixed

- Fixed world age warnings (`WARNING: Detected access to binding 'xxx' in a world prior to its definition world. ...`) that could occur when the language server interacts with user-defined methods or types at a newer world age.
  This affected diagnostic printing, documentation lookup (hover, completions), and signature help display.
  (Closed https://github.com/aviatesk/JETLS.jl/issues/485)

- Fixed full analysis not working on unsaved (`untitled:`) buffers.
  Unlike saved files where analysis runs on save, unsaved buffers trigger
  analysis on each content change with a fixed 3-second debounce.

- Fixed lowering-based LSP features (document highlight, go-to-definition, find references, rename, hover) not working for functions with docstrings.

- Fixed go-to-definition, find references, rename, and code actions not working correctly in notebooks.

## 2026-03-20

- Commit: [`d14efce`](https://github.com/aviatesk/JETLS.jl/commit/d14efce)
- Diff: [`ea73622...d14efce`](https://github.com/aviatesk/JETLS.jl/compare/ea73622...d14efce)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-03-20")'
  ```

### Added

- Added process title setting so that `jetls serve` processes are distinguishable in `ps`/`htop` when multiple projects are open.
  The title includes JETLS version, workspace path, transport mode, and client process ID.

### Fixed

- Fixed false positive `lowering/unused-assignment` diagnostic for variables reassigned inside `while` loops with `break`/`continue`.

## 2026-03-19

- Commit: [`ea73622`](https://github.com/aviatesk/JETLS.jl/commit/ea73622)
- Diff: [`4280097...ea73622`](https://github.com/aviatesk/JETLS.jl/compare/4280097...ea73622)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-03-19")'
  ```

### Added

- Added `@main` function support across LSP features (document-symbol, document-highlight, references, rename, completions, diagnostic).

- Added `lowering/unused-assignment` diagnostic that detects assignments whose values are never read (dead stores).
  This complements the existing `lowering/unused-local` diagnostic: `lowering/unused-local` reports variables that are never used at all, while `lowering/unused-assignment` reports specific assignments to variables that *are* used elsewhere.
  For example:
  ```julia
  function f(x::Bool)
      if x
          z = "Hi"
          println(z)  # z is used, so no `unused-local`
      end
      if x
          z = "Hey"   # but this value is never read → `unused-assignment`
      end
  end
  ```

### Changed

- `lowering/undef-local-var` now reports a diagnostic for each use site on an undef path individually, rather than only reporting the first one.
- `lowering/undef-local-var` `@isdefined` propagation now recognizes `@isdefined(var)` within `&&` chains (e.g., `if cond && @isdefined(y)`), suppressing false positive diagnostics in the guarded branch.
- Updated JuliaSyntax.jl and JuliaLowering.jl dependency versions to latest

### Fixed

- Fixed false positive `lowering/unused-binding` warning for keyword arguments that are only used in computing other keyword arguments' default values (Closed https://github.com/aviatesk/JETLS.jl/issues/592).
- Fixed false positive `lowering/unused-import` warning for imports used inside quoted expressions in macro bodies or helper functions (Closed https://github.com/aviatesk/JETLS.jl/issues/594).
- Fixed `lowering/undef-local-var` diagnostic being reported at the wrong location:
  when a variable had both defined and potentially-undefined uses, the diagnostic pointed to the first use in source order rather than the use that is actually on the undef path.
- Fixed signature-help error when displaying signatures for operator-like methods (e.g. `Base.:(==)`).
- Fixed "Delete assignment" code action removing the opening delimiter of string literals (e.g., `z = "Hey"` became `Hey"` instead of `"Hey"`).

## 2026-03-13

- Commit: [`4280097`](https://github.com/aviatesk/JETLS.jl/commit/4280097)
- Diff: [`d32f1cf...4280097`](https://github.com/aviatesk/JETLS.jl/compare/d32f1cf...4280097)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-03-13")'
  ```

### Changed

- Updated JuliaSyntax.jl and JuliaLowering.jl dependency versions to latest

### Fixed

- Fixed crash in diagnostics when `@generated` functions use old-style macros
  (Closed https://github.com/aviatesk/JETLS.jl/issues/583).

- Fixed false `"Invalid type signature for @kwdef"` error when using `@kwdef`
  with subtype declarations (e.g. `@kwdef struct A <: B`)
  (Closed https://github.com/aviatesk/JETLS.jl/issues/587).

- Fixed false `unused-import` warnings for modules with docstrings
  (Closed https://github.com/aviatesk/JETLS.jl/issues/586).

- Fixed server hang when the client terminates abnormaly without sending an
  `exit` notification (e.g. Neovim)
  (Fixed https://github.com/aviatesk/JETLS.jl/pull/580).

## 2026-03-08

- Commit: [`d32f1cf`](https://github.com/aviatesk/JETLS.jl/commit/d32f1cf)
- Diff: [`5e1f0bb...d32f1cf`](https://github.com/aviatesk/JETLS.jl/compare/5e1f0bb...d32f1cf)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-03-08")'
  ```

### Changed

- Updated JuliaSyntax and JuliaLowering to their latest versions, fixing
  several errors caused by JuliaLowering
  (Fixed https://github.com/aviatesk/JETLS.jl/issues/495,
  https://github.com/aviatesk/JETLS.jl/issues/518,
  https://github.com/aviatesk/JETLS.jl/issues/538).

### Fixed

- Fixed highlight range in `jetls check` (https://github.com/aviatesk/JETLS.jl/pull/574).
- Fixed false "unused argument" warnings for `@generated` functions.
  Arguments used inside quoted expressions (`:(...)`) are now correctly
  recognized. Document highlight, find references, and rename also work
  for these arguments
  (Closed https://github.com/aviatesk/JETLS.jl/issues/480).

## 2026-02-27

- Commit: [`5e1f0bb`](https://github.com/aviatesk/JETLS.jl/commit/5e1f0bb)
- Diff: [`ebcbd60...5e1f0bb`](https://github.com/aviatesk/JETLS.jl/compare/ebcbd60...5e1f0bb)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-02-27")'
  ```

### Added

- Added a GitHub composite action (`.github/actions/check/`) for running
  `jetls check` in CI pipelines. External packages can use it as:
  ```yaml
  - uses: aviatesk/JETLS.jl/.github/actions/check@release
    with:
      files: src/SomePkg.jl
  ```
  All `jetls check` command-line options are available as action inputs.

### Changes

- The previously deprecated behavior of running `jetls` without a subcommand
  to start the language server has been removed. Running `jetls` without a
  subcommand or with unrecognized arguments now shows the help message and
  exits. Use `jetls serve` instead
  (Closed https://github.com/aviatesk/JETLS.jl/issues/565).

## 2026-02-26

- Commit: [`ebcbd60`](https://github.com/aviatesk/JETLS.jl/commit/ebcbd60)
- Diff: [`e141508...ebcbd60`](https://github.com/aviatesk/JETLS.jl/compare/e141508...ebcbd60)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-02-26")'
  ```

### Added

- Added [`inference/method-error`](https://aviatesk.github.io/JETLS.jl/release/diagnostic/#diagnostic/inference/method-error)
  diagnostic that detects function calls where no matching method exists for
  the inferred argument types. This catches potential `MethodError`s that would
  occur at runtime. For union-split calls, the diagnostic reports only the
  failing branches with their count (e.g., "1/2 union split").

- Added `jetls schema` CLI command that prints the JSON Schema for JETLS
  configuration. Supports `--settings`, `--init-options`, and
  `--config-toml` options.
- Added schema generation infrastructure under `scripts/schema/` and
  committed generated schema files under `schemas/`. CI now checks that
  the schema files and `jetls-client/package.json` stay in sync with
  `src/types.jl`.

### Changed

- `textDocument/documentSymbol` now shows `for`, `let`, `while`, and
  `try`/`catch`/`else`/`finally` blocks inside functions as hierarchical
  `Namespace` symbols. Previously, all local bindings within a function were
  shown as flat children; now, bindings inside scope constructs are nested
  under the scope construct, matching the existing behavior for top-level
  scope constructs.

- `textDocument/documentSymbol` now strips redundant name prefixes from
  symbol details. (e.g., a symbol named `foo` with detail `foo = func(args...)`
  now shows ` = func(args...)` as the detail.

### Fixed

- Fixed `textDocument/rename` for macro bindings.

- Fixed bindings in `let`/`for`/`while` blocks inside nested functions
  not appearing as children of those functions in the document outline.

## 2026-02-16

- Commit: [`e141508`](https://github.com/aviatesk/JETLS.jl/commit/e141508)
- Diff: [`150f880...e141508`](https://github.com/aviatesk/JETLS.jl/compare/150f880...e141508)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-02-16")'
  ```

### Added

- Anonymous function assignments (`f = (x) -> x + 1` and
  `clos = function (y) ... end`) are now analyzed as `Function` symbols
  for `textDocument/documentSymbol`, with their arguments as children.

### Changed

- Enabled signature analysis for all analysis modes. Previously, signature
  analysis was only active in the package source analysis, meaning some
  potential errors within standalone scripts can be missed.
  This change ensures that diagnostics like `inference/field-error`
  can be detected from methods within standalone scripts.
  (Fixed https://github.com/aviatesk/JETLS.jl/issues/479).

### Fixed

- Fixed `jetls check` failing to correctly activate user package environments
  during full analysis.

- Fixed `jetls check` resolving file path arguments relative to the current
  working directory instead of the `--root` directory when `--root` is specified.
  For example, `jetls check --root=/path/to/Pkg src/Pkg.jl` now correctly
  resolves to `/path/to/Pkg/src/Pkg.jl`.

- Fixed false positive `lowering/unused-import` diagnostics for symbols
  in a package file but used in `include`d files
  (Fixed https://github.com/aviatesk/JETLS.jl/issues/547).

- Fixed rename/document-highlight/references failing for `@kwdef` structs with
  default values (Fixed https://github.com/aviatesk/JETLS.jl/issues/540).

- Fixed duplicate syntax error diagnostics by skipping `ParseErrorReport` from
  full-analysis, since syntax errors are already reported via
  `textDocument/diagnostic` or `workspace/diagnostic`
  (Fixed https://github.com/aviatesk/JETLS.jl/issues/535).

- Fixed false positive unused argument diagnostic for keyword arguments whose
  type annotation constrains a `where`-clause static parameter that is used in
  the function body (e.g., `f(; dtype::Type{T}=Float32) where {T} = T.(xs)`)
  (Fixed https://github.com/aviatesk/JETLS.jl/issues/481).

- Fixed various type instabilities across the codebase caught by the new
  `inference/method-error` diagnostic running on JETLS itself.

### Other

- Added GitHub issue templates for bug reports and feature requests.

## 2026-02-11

- Commit: [`150f880`](https://github.com/aviatesk/JETLS.jl/commit/150f880)
- Diff: [`9c00dfe...150f880`](https://github.com/aviatesk/JETLS.jl/compare/9c00dfe...150f880)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-02-11")'
  ```

### Added

- Added [`jetls check`](https://aviatesk.github.io/JETLS.jl/release/cli-check/) command
  for running JETLS diagnostics from the command line. This enables CI integration
  and command-line workflows without requiring an editor. Features include
  `--exit-severity` for controlling exit codes, `--show-severity` for filtering
  output, `--context-lines` for output formatting, and `--root` for configuration
  lookup. The CLI now uses a subcommand structure: `jetls serve` starts the
  language server (default), while `jetls check` runs diagnostics.

- Added [`lowering/unused-import`](https://aviatesk.github.io/JETLS.jl/release/diagnostic/#diagnostic/reference/lowering/unused-import)
  diagnostic that reports explicitly imported names that are never used within
  the same module space. The "Remove unused import" code action removes the
  unused name from the import statement.

- Added reference count code lens for top-level symbols (functions, structs,
  constants, abstract types, primitive types, modules). When enabled, a code
  lens showing "N references" appears above each symbol definition. Clicking it
  opens the references panel. This feature is opt-in and can be enabled via
  [`code_lens.references`](https://aviatesk.github.io/JETLS.jl/release/features/#features/code-lens/references)
  configuration.

- Added [`code_lens.testrunner`](https://aviatesk.github.io/JETLS.jl/release/configuration/#config/code_lens/testrunner)
  configuration option to enable or disable TestRunner code lenses. Some editors
  (e.g., Zed) display code lenses as code actions, causing duplication.
  The [aviatesk/zed-julia](https://github.com/aviatesk/zed-julia) extension
  automatically defaults this to `false`.

- Added document symbol support for `if` and `@static if` blocks. These blocks
  now appear in the document outline as `SymbolKind.Namespace` symbols, with
  all definitions from `if`/`elseif`/`else` branches flattened as children.

- Added document symbol support for `@testset` and `@test` macros. `@testset`
  blocks appear in the document outline with the test name, and `@test`
  expressions appear as children showing the test expression.

- Added inlay hints for block `end` keywords. For long blocks (`module`,
  `function`, `macro`, `struct`, `if`/`@static if`, `let`, `for`, `while`,
  `@testset`), an inlay hint is displayed at the `end` keyword showing what
  construct is ending, such as `module Foo` or `function bar`. The minimum
  block length can be configured via
  [`inlay_hint.block_end_min_lines`](https://aviatesk.github.io/JETLS.jl/release/configuration/#config/inlay_hint/block_end_min_lines)
  (default: 25 lines).

### Deprecated

- Running `jetls` without a subcommand (e.g., `jetls --stdio`) is deprecated.
  Use `jetls serve` instead. The support for `jetls` without a subcommand will
  be removed in a future release.

### Changed

- Namespace symbols (`if`/`let`/`for`/`while`/`@static if` blocks) are now
  excluded from workspace symbol search. These symbols exist only to provide
  hierarchical structure in the document outline, not to represent actual
  definitions.

- `textDocument/diagnostic` now supports cancellation, avoiding to compute
  staled diagnostics (https://github.com/aviatesk/JETLS.jl/pull/524)

- Updated JuliaSyntax.jl and JuliaLowering.jl dependency versions to latest,
  fixing the root causes of https://github.com/aviatesk/JETLS.jl/issues/492,
  and https://github.com/aviatesk/JETLS.jl/issues/508.

### Fixed

- Lowering diagnostics no longer report issues in macro-generated code that
  users cannot control. User-written identifiers processed by new-style macros
  are still reported, but old-style macros are not yet supported due to
  JuliaLowering limitations.

- Fixed false positive `lowering/unused-argument` and `lowering/unused-local`
  diagnostics that could appear before full-analysis completes when macros
  cannot be expanded. Fixed https://github.com/aviatesk/JETLS.jl/issues/522.

- Fixed diagnostic configuration pattern merging to use composite keys.
  Previously, patterns with the same `pattern` value but different `path` would
  overwrite each other.
  Now patterns are identified by `(match_by, match_type, path, pattern)`,
  allowing multiple rules for the same pattern with different paths.

- Fixed potential segfault on server exit by implementing graceful shutdown of
  worker tasks. All `Threads.@spawn`ed tasks are now properly terminated before
  the server exits. (xref: https://github.com/JuliaLang/julia/issues/32983, https://github.com/aviatesk/JETLS.jl/pull/523)

- Fixed thread-safety issue with cached syntax trees. Multiple threads accessing
  the same cached tree during lowering could cause data races and segfaults.
  Cached trees are now copied before use. (https://github.com/aviatesk/JETLS.jl/pull/525)

- Fixed cache not being generated in some cases in the experimental incremental
  analysis mode. The cache is now always created when `CodeInstance` is
  available, ensuring cache reuse works reliably.

- Fixed auto-instantiate creating unwanted versioned manifest files (e.g.,
  `Manifest-v1.12.toml`) via `touch`. A manifest is now only created when
  `Pkg.instantiate()` needs one.
  (https://github.com/aviatesk/JETLS.jl/issues/511,
   https://github.com/aviatesk/JETLS.jl/pull/536;
   thanks [visr](https://github.com/visr))

## 2026-01-23

- Commit: [`9c00dfe`](https://github.com/aviatesk/JETLS.jl/commit/9c00dfe)
- Diff: [`c8e2012...9c00dfe`](https://github.com/aviatesk/JETLS.jl/compare/c8e2012...9c00dfe)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-01-23")'
  ```

### Added

- Added [`workspace/diagnostic`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspace_diagnostic)
  support to provide `JETLS/live` diagnostics (syntax errors and lowering-based
  analysis) for unopened files in the workspace.

- Added [`diagnostic.all_files`](https://aviatesk.github.io/JETLS.jl/release/configuration/#config/diagnostic/all_files)
  configuration option to control whether diagnostics are reported for unopened
  files. Disabling this can be useful to reduce noise when there are many
  warnings across the workspace.

- Added [`lowering/unsorted-import-names`](https://aviatesk.github.io/JETLS.jl/release/diagnostic/#diagnostic/reference/lowering/unsorted-import-names)
  diagnostic that reports when names in `import`, `using`, `export`, or `public`
  statements are not sorted alphabetically. The "Sort import names" code action
  is available to automatically fix the ordering.

- `textDocument/documentHighlight` now supports macro bindings. Highlighting a
  macro name (either in the definition or at a call site) shows all occurrences
  of that macro within the document.

- `textDocument/references` now supports macro bindings. Finding references on
  a macro name (either in the definition or at a call site) shows all
  occurrences of that macro across the package.

### Changed

- Updated TestRunner.jl installation instructions to use the `#release` branch
  for vendored dependencies. TestRunner.jl should now be installed via
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/TestRunner.jl", rev="release")'
  ```
  (aviatesk/TestRunner.jl#14).

- Replaced `inference/undef-local-var` with new `lowering/undef-local-var`
  diagnostic. The new diagnostic uses CFG-aware analysis on lowered code,
  providing faster feedback via `textDocument/diagnostic` without waiting for
  full analysis, and offers precise source location information. See the
  [diagnostic reference](https://aviatesk.github.io/JETLS.jl/release/diagnostic/#diagnostic/reference/lowering/undef-local-var)
  for details and workarounds.

- `textDocument/documentSymbol` now uses `SymbolKind.Object` for function
  arguments instead of `SymbolKind.Variable`. This visually distinguishes
  arguments from local variables in the document outline. Since LSP does not
  provide a dedicated `SymbolKind.Argument`, `Object` is used as a workaround.

- `workspace/symbol` now shows the parent function signature or struct name as
  the container name for arguments or fields respectively, making it clearer
  which function or struct they belong to during workspace symbol search.

- Diagnostic `source` field now uses distinct values to indicate which channel
  delivers the diagnostic: `JETLS/live` for on-change diagnostics, `JETLS/save`
  for on-save full analysis, and `JETLS/extra` for external sources like the
  TestRunner.jl integration. This helps users understand when diagnostics update
  and enables filtering by source in editors that support it. See the
  [Sources](https://aviatesk.github.io/JETLS.jl/release/diagnostic/#diagnostic/source)
  documentation for details.

- Yet more improved performance of `workspace/symbol`, `textDocument/references`,
`textDocument/rename`, and `textDocument/definition` by avoiding re-parsing of
  already analyzed files not opened in the editor.

- `workspace/configuration` requests now expect settings to be found under the
  top-level `"jetls"` key, such that a request with `section = "jetls"` produces
  the full configuration. This is to ensure compatibility with generic clients,
  e.g., the neovim client, which may not conform to JETLS's previous
  expectations about how requests with no `section` are handled.
  (https://github.com/aviatesk/JETLS.jl/pull/483; thanks [danielwe](https://github.com/danielwe))

- Updated JuliaSyntax.jl and JuliaLowering.jl dependency versions to latest.

### Fixed

- Fixed LSP features not working inside `@main` functions.

- Fixed false positive `lowering/captured-boxed-variable` diagnostic when a
  struct's inner constructor defines a local variable with the same name as a
  type parameter (e.g., `struct Foo{T}` with `T = typeof(x)` in the constructor).
  (https://github.com/aviatesk/JETLS.jl/issues/508)

- Fixed severe performance issue when analyzing test files containing many
  `@test` and `@testset` macros. The underlying JuliaLowering issue caused
  macro expansion to be 40-300x slower for test files compared to regular source
  files. (JuliaLang/julia#60756)

## 2026-01-17

- Commit: [`c8e2012`](https://github.com/aviatesk/JETLS.jl/commit/c8e2012)
- Diff: [`4cf9994...c8e2012`](https://github.com/aviatesk/JETLS.jl/compare/4cf9994...c8e2012)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-01-17")'
  ```

### Added

- `textDocument/definition` now supports global bindings. Previously,
  go-to-definition for global variables couldn't find their definition sites
  since runtime reflection doesn't provide binding location information.
  Now it uses binding occurrence analysis to find definition sites across
  the package, benefiting from the binding occurrences cache.

### Changed

- Improved `workspace/symbol` performance by enabling document symbol caching for
  files not currently open in the editor. Previously, only synced files (opened
  in editor) used the cache, causing repeated parsing for every workspace symbol
  search. The cache is now invalidated via `workspace/didChangeWatchedFiles`
  when unsynced files change on disk.

- Improved `textDocument/references`, `textDocument/rename`, and
  `textDocument/documentHighlight` performance for global bindings by caching
  binding occurrence analysis results per top-level expression. The cache
  persists across requests within the same package, so consecutive
  find-references, rename, or document highlight operations avoid redundant
  lowering.

## 2026-01-15

- Commit: [`4cf9994`](https://github.com/aviatesk/JETLS.jl/commit/4cf9994)
- Diff: [`54b3058...4cf9994`](https://github.com/aviatesk/JETLS.jl/compare/54b3058...4cf9994)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-01-15")'
  ```

### Added

- Implemented `textDocument/documentSymbol` for structured outline view in editors.
  Provides hierarchical symbol information including modules, functions, structs,
  and local variables with rich detail context.

  <img alt="textDocument/documentSymbol" src="https://github.com/user-attachments/assets/80b9d743-9a81-46e6-bb2b-692d8b6598b4" />

- Implemented `workspace/symbol` for workspace-wide symbol search, allowing
  quickly jumping to any function, type, or variable across the workspace.
  Results include rich context like function signatures for easier identification.

  <img alt="workspace/symbol" src="https://github.com/user-attachments/assets/7ed8b366-d72f-49ff-9dbd-5a18ef66c2b7" />

### Changed

- Updated JuliaSyntax.jl and JuliaLowering.jl dependency versions to latest.

## 2026-01-11

- Commit: [`54b3058`](https://github.com/aviatesk/JETLS.jl/commit/54b3058)
- Diff: [`8b3c9db...54b3058`](https://github.com/aviatesk/JETLS.jl/compare/8b3c9db...54b3058)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-01-11")'
  ```

### Fixed

- Fixed cancellation not working properly for formatting requests
  (Fixed https://github.com/aviatesk/JETLS.jl/issues/465)

- Fixed diagnostic `relatedInformation` range not being localized for notebook cells

## 2026-01-10

- Commit: [`8b3c9db`](https://github.com/aviatesk/JETLS.jl/commit/8b3c9db)
- Diff: [`cbcdc3c...8b3c9db`](https://github.com/aviatesk/JETLS.jl/compare/cbcdc3c...8b3c9db)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-01-10")'
  ```

### Added

- Added `lowering/captured-boxed-variable` diagnostic that reports variables
  captured by closures requiring boxing. E.g.:
  ```julia
  function abmult1(r::Int)  # `r` is captured and boxed (JETLS lowering/captured-boxed-variable)
      if r < 0
          r = -r
      end
      f = x -> x * r        # RelatedInformation: Closure at L5:9 captures `r`
      return f
  end
  ``` (https://github.com/aviatesk/JETLS.jl/pull/452)

### Changed

- Keyword argument name completion items are now sorted according to their order
  in the method definition.

### Fixed

- Fixed `textDocument/diagnostic` for notebook cells.

- Fixed `textDocument/formatting` and `textDocument/rangeFormatting` for
  notebook cells (Fixed the first issue of https://github.com/aviatesk/JETLS.jl/issues/442).

- Return empty results instead of errors for LSP requests on documents that
  haven't been synchronized via `textDocument/didOpen`
  (Fixed the second issue of https://github.com/aviatesk/JETLS.jl/issues/442).

- Fixed `lowering/undef-global-var` diagnostic incorrectly reporting
  non-constant but defined symbols as undefined in the file-analysis mode.

- Fixed cancellation not working for requests that use server-initiated progress
  (e.g., `textDocument/formatting`, `textDocument/rename`, `textDocument/references`).
  Previously, these requests were marked as handled immediately when the handler
  returned, causing `$/cancelRequest` to be ignored.

- Fixed progress UI cancel button not being displayed for `textDocument/formatting`,
  `textDocument/rangeFormatting`, `textDocument/references`, and
  `textDocument/rename` requests. The server now properly handles both
  `$/cancelRequest` and `window/workDoneProgress/cancel` to abort these requests.

## 2026-01-09

- Commit: [`cbcdc3c`](https://github.com/aviatesk/JETLS.jl/commit/cbcdc3c)
- Diff: [`368e0a1...cbcdc3c`](https://github.com/aviatesk/JETLS.jl/compare/368e0a1...cbcdc3c)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-01-09")'
  ```

### Fixed

- Fixed `lowering/undef-global-var` diagnostic incorrectly reporting imported
  symbols from dependency packages as undefined.
  when `!JETLS_DEV_MODE`. (https://github.com/aviatesk/JETLS.jl/issues/457)

- Fixed false positive `lowering/undef-global-var` diagnostic for keyword slurp
  arguments with dependent defaults (e.g., `f(; a=1, b=a, kws...)`).
  (JuliaLang/julia#60600)

## 2026-01-08

- Commit: [`368e0a1`](https://github.com/aviatesk/JETLS.jl/commit/368e0a1)
- Diff: [`c5f3c0d...368e0a1`](https://github.com/aviatesk/JETLS.jl/compare/c5f3c0d...368e0a1)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-01-08")'
  ```

### Added

- Added `lowering/undef-global-var` diagnostic that reports undefined global
  variable references on document change (as you type). This provides faster
  feedback compared to `inference/undef-global-var`, which runs on save.
  The on-change diagnostic detects simple undefined references with accurate
  position information, while the on-save version detects a superset of
  undefined global binding references, including qualified references like
  `Base.undefvar`. (https://github.com/aviatesk/JETLS.jl/pull/450)

  <https://github.com/user-attachments/assets/7825c938-5dae-4bb8-9c84-b95e788461e8>

- Method signature completion for function calls. When typing inside a function
  call (triggered by `(`, `,`, or ` `), compatible method signatures are
  suggested based on already-provided arguments. Selecting a completion inserts
  remaining positional arguments as snippet placeholders with type annotations.
  When you select a completion item in the list, additional details such as
  inferred return type and documentation are displayed (resolved lazily for
  performance). (https://github.com/aviatesk/JETLS.jl/pull/428)

  <https://github.com/user-attachments/assets/19d320a6-459f-4788-9669-d3936920b625>

- Keyword argument name completion for function calls. When typing inside a
  function call (e.g., `func(; |)` or `func(k|)`), available keyword arguments
  are suggested with `=` appended. Already-specified keywords are excluded from
  suggestions, and the spacing around `=` follows the existing style in the call.
  (https://github.com/aviatesk/JETLS.jl/pull/427)

  <https://github.com/user-attachments/assets/d3cdecea-d2eb-4d14-9043-6bc62a6f2833>

- Added `completion.latex_emoji.strip_prefix` configuration option to control
  prefix stripping in LaTeX/emoji completions. Some editors (e.g., Zed) don't
  handle backslash characters in the LSP `sortText` field, causing incorrect
  completion order. Set to `true` to strip prefixes, `false` to keep them.
  If not set, JETLS auto-detects based on client. The auto-detection covers
  only a limited set of known clients, so users experiencing sorting issues
  should explicitly set this option.

- Added `completion.method_signature.prepend_inference_result` configuration
  option to control whether to prepend inferred return type information to the
  documentation of method signature completion items. In some editors (e.g., Zed),
  additional information like inferred return type displayed when an item is
  selected may be cut off in the UI when method signature text is long. Set to
  `true` to show return type in documentation. If not set, JETLS auto-detects
  based on client. The auto-detection covers only a limited set of known clients,
  so users experiencing visibility issues should explicitly set this option.

> [!tip]
> **Help improve auto-detection**:
>
> Some completion configuration options (e.g., `completion.latex_emoji.strip_prefix`,
> `completion.method_signature.prepend_inference_result`) use client-based
> auto-detection for default behavior. If explicitly setting these options clearly
> improves behavior for your client, consider submitting a PR to add your client
> to the [auto-detection](https://github.com/aviatesk/JETLS.jl/blob/14fdc847252579c27e41cd50820aee509f8fd7bd/src/completions.jl#L386) logic.

- Added code actions to delete unused variable assignments. For unused local
  bindings like `y = println(x)`, two new quick fix actions are now available:
  - "Delete assignment": removes `y = `, leaving just `println(x)`
  - "Delete statement": removes the entire assignment statement
  These actions are not shown for (named)tuple destructuring patterns like
  `x, y, z = func()` where deletion would change semantics.

### Changed

- Enhanced global completion items with detailed kind information (`[function]`,
  `[type]`, `[module]`, etc.). When you select a completion item, these
  details are displayed (resolved lazily for performance). The visibility of
  these enhancements varies by client: VSCode updates only the `CompletionItem.detail`
  field (shown above documentation), while Zed is able to update all fields including
  `CompletionItem.kind` for richer presentation with label highlighting
  (combined with https://github.com/aviatesk/zed-julia/pull/1). (https://github.com/aviatesk/JETLS.jl/pull/425)

  > Demo with [aviatesk/zed-julia](https://github.com/aviatesk/zed-julia)

  <https://github.com/user-attachments/assets/a39d7bc5-c46e-40c8-a9ee-0458b3abdcae>

- Improved signature help filtering when a semicolon is present in function calls.
  Methods that require more positional arguments than provided are now filtered
  out once the user enters the keyword argument region (e.g., `g(42;│)` no longer
  shows `g(x, y)` which requires 2 positional arguments). (https://github.com/aviatesk/JETLS.jl/pull/426)

- Signature help and method completion now use type-based filtering. Method
  candidates are filtered based on the inferred types of already-provided
  arguments. For example, signature help and method completions triggered by
  typing `sin(1,│` now shows only `sin(::Real)` instead of all `sin` methods.
  Global constants are also resolved (e.g., `sin(gx,│)` with `const gx = 42`
  correctly infers `Int`). Note that local variable types are not yet resolved,
  (e.g., `let x = 1; sin(x,│); end` would still show all `sin` methods). (https://github.com/aviatesk/JETLS.jl/pull/436)

- Signature help now displays the inferred argument type for the active
  parameter. The parameter documentation shows the passed argument expression
  and its type (e.g., `p ← (arg) :: Int64`).

  https://github.com/user-attachments/assets/a222a44d-9d46-435c-8759-8157005cfc38

- Updated JuliaSyntax.jl and JuliaLowering.jl dependency versions to latest.

- Updated Revise.jl dependency version to v3.13.

### Fixed

- Improved type resolver robustness, eliminating `UndefVarError` messages that
  could appear in server logs during signature help. Fixed https://github.com/aviatesk/JETLS.jl/issues/391. (https://github.com/aviatesk/JETLS.jl/pull/435)

- Fixed signature help parameter highlighting when cursor is not inside any
  argument. For positional arguments exceeding the parameter count, the last
  (vararg) parameter is now highlighted (e.g. `println(stdout,"foo","bar",│)`).
  For keyword arguments after a semicolon, the next unspecified keyword
  parameter is highlighted (e.g., `printstyled("foo"; bold=true,│)` highlights `italic`).

## 2026-01-01

- Commit: [`c5f3c0d`](https://github.com/aviatesk/JETLS.jl/commit/c5f3c0d)
- Diff: [`b61b6fa...c5f3c0d`](https://github.com/aviatesk/JETLS.jl/compare/b61b6fa...c5f3c0d)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2026-01-01")'
  ```

### Fixed

- Fixed method overwrite detection to handle both `Core.CodeInfo` and `Expr`
  source types, making the analysis more robust. (https://github.com/aviatesk/JETLS.jl/pull/421)
- Fixed `toplevel/abstract-field` diagnostic to report correct field locations
  for structs with `<:` subtyping syntax and `const` field modifiers. (https://github.com/aviatesk/JETLS.jl/pull/422)

## 2025-12-31

- Commit: [`b61b6fa`](https://github.com/aviatesk/JETLS.jl/commit/b61b6fa)
- Diff: [`afc5137...b61b6fa`](https://github.com/aviatesk/JETLS.jl/compare/afc5137...b61b6fa)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2025-12-31")'
  ```

### Added

- Added `diagnostic.allow_unused_underscore` configuration option (default: `true`).
  When enabled, unused variable diagnostics (`lowering/unused-argument` and
  `lowering/unused-local`) are suppressed for names starting with `_`.
  (https://github.com/aviatesk/JETLS.jl/pull/415)
- Added code action to prefix unused variables with `_`. When triggered on an
  unused variable diagnostic, this quickfix inserts `_` at the beginning of
  the variable name to suppress the warning.
  (https://github.com/aviatesk/JETLS.jl/pull/416)
- Added warning diagnostic for method overwrites (`toplevel/method-overwrite`).
  When a method with the same signature is defined multiple times within a
  package, a warning is reported at the overwriting definition with a link to
  the original definition. Addresses
  https://github.com/aviatesk/JETLS.jl/issues/387.
  (https://github.com/aviatesk/JETLS.jl/pull/417)

  <img alt="toplevel/method-overwrite showcase" src="https://github.com/user-attachments/assets/5c4aa6f7-ebd8-4e07-b3c6-ad6159a76508">

- Added information diagnostic for abstract field types (`toplevel/abstract-field`).
  Reports when a struct field has an abstract type (e.g., `Vector{Integer}` or
  `Pair{Int}`), which often causes performance issues such as dynamic dispatch.
  (https://github.com/aviatesk/JETLS.jl/pull/418, https://github.com/aviatesk/JETLS.jl/pull/419)

  <img alt="toplevel/abstract-field showcase" src="https://github.com/user-attachments/assets/b5f925bb-d518-4e6c-893d-2f91fb1965f6">

### Fixed

- Added patch to vendored JuliaLowering to support `@.` macro expansion.
  This was addressed with a specific patch for the `@.` case, but many of these
  JuliaLowering macro compatibility issues are planned to be resolved
  generically in the future. Fixed https://github.com/aviatesk/JETLS.jl/issues/409.

## 2025-12-19

- Commit: [`afc5137`](https://github.com/aviatesk/JETLS.jl/commit/afc5137)
- Diff: [`c9c5729...afc5137`](https://github.com/aviatesk/JETLS.jl/compare/c9c5729...afc5137)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2025-12-19")'
  ```

### Added

- Added CHANGELOG page to the documentation.

### Fixed

- Fixed `inference/undef-global-var` diagnostic being unintentially reported for
  undefined global bindings in dependency packages.
- Fixed syntax/lowering diagnostics not being refreshed when diagnostic
  configuration change via `.JETLSConfig.toml` or LSP configuration. The server
  now sends `workspace/diagnostic/refresh` request to prompt clients to re-pull
  diagnostics. Note that client support varies; e.g. VSCode refreshes
  `textDocument/diagnostic` in response, but Zed does not.

## 2025-12-18

- Commit: [`c9c5729`](https://github.com/aviatesk/JETLS.jl/commit/c9c5729)
- Diff: [`048d9a5...c9c5729`](https://github.com/aviatesk/JETLS.jl/compare/048d9a5...c9c5729)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2025-12-18")'
  ```

### Added

- Added `inference/field-error` diagnostic for detecting access to non-existent
  struct fields (e.g., `x.propert` when the field is `property`).
  Closed https://github.com/aviatesk/JETLS.jl/issues/392.
- Added `inference/bounds-error` diagnostic for detecting out-of-bounds field
  access by index (e.g., `tpl[2]` on a `tpl::Tuple{Int}`).
  Note that this diagnostic is for struct/tuple field access, not array indexing.
- Added completion support for Julia keywords.
  Closed https://github.com/aviatesk/JETLS.jl/issues/386.
- Added hover documentation for Julia keywords.
- Initialization options can now be configured via `.JETLSConfig.toml` using the
  `[initialization_options]` section. See the [documentation](https://aviatesk.github.io/JETLS.jl/release/launching/#init-options/configure)
  for details.
- Added file rename support. When renaming a string literal that refers to a
  valid file path (e.g., in `include("foo.jl")`), JETLS now renames both the
  file on disk and updates the string reference in the source code.
  Note that this feature only works when initiating rename from within the
  Julia source code; renaming files externally (e.g., via editor file explorer)
  will not automatically update code references.

### Fixed

- Small adjustments for using JETLS with Julia v1.12.3
- Fixed false negative unused argument diagnostics for functions with keyword
  arguments. For example, `func(a; kw=nothing) = kw` now correctly reports
  `a` as unused. Fixed https://github.com/aviatesk/JETLS.jl/issues/390.
- Fixed stale diagnostics not being cleared when a file is closed or when test
  structure changes remove all diagnostics for a URI.
- Fixed wrong message for diagnostic with multiple stack frames.
  The diagnostic message could be incorrectly overwritten when there are multiple
  stack frames, causing "message must be set" errors in VSCode.
  Fixed https://github.com/aviatesk/JETLS.jl/issues/393.

### Changed

- Completions now return no results when the prefix type is unknown.
  Previously, irrelevant completions were shown for expressions like
  `obj.x` where `obj`'s type could not be resolved.
  Fixed https://github.com/aviatesk/JETLS.jl/issues/389.
- Invalid initialization options are now reported to the user via editor
  notifications instead of only being logged to the server.

## 2025-12-12

- Commit: [`048d9a5`](https://github.com/aviatesk/JETLS.jl/commit/048d9a5)
- Diff: [`9b39829...048d9a5`](https://github.com/aviatesk/JETLS.jl/compare/9b39829...048d9a5)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2025-12-12")'
  ```

### Added

- Added `textDocument/references` support for bindings. Both local and global
  bindings are supported, although currently the support for global references
  is experimental and has some notable limitations:
  - References can only be found within the same analysis unit. For example,
    when finding references to `somebinding` defined in `PkgA/src/somefile.jl`,
    usages in `PkgA/src/` can be found, but usages in `PkgA/test/` cannot be
    detected because test files are in a separate analysis unit.
  - Aliasing is not considered. Usages via `using ..PkgA: somebinding as otherbinding`
    or module-qualified access like `PkgA.somebinding` are not detected.
- Added `textDocument/rename` support for global bindings. Similar to global
  references, this feature is experimental and has the same limitations
  regarding analysis unit boundaries and aliasing.

### Fixed

- Fixed false positive unused variable diagnostics in comprehensions with filter
  conditions. For example, `[x for (i, x) in enumerate(xs) if isodd(i)]` no
  longer incorrectly reports `i` as unused.
  Fixes https://github.com/aviatesk/JETLS.jl/issues/360.

### Changed

- Updated JuliaSyntax.jl and JuliaLowering.jl dependencies to the latest
  development versions, which fixes spurious lowering diagnostics that occurred
  in edge cases such as JuliaLang/julia#60309.

## 2025-12-08

- Commit: [`9b39829`](https://github.com/aviatesk/JETLS.jl/commit/9b39829)
- Diff: [`fd5f113...9b39829`](https://github.com/aviatesk/JETLS.jl/compare/fd5f113...9b39829)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2025-12-08")'
  ```

### Added

- Jupyter notebook support: JETLS now provides language features for Julia code
  cells in Jupyter notebooks. As shown in the demo below, all code cells are
  analyzed together as a single source, as if the notebook were a single Julia
  script. JETLS is aware of all cells, so features like go-to-definition,
  completions, and diagnostics work across cells just as they would in a
  regular Julia script.

  > JETLS × notebook LSP demo

  <https://github.com/user-attachments/assets/b5bb5201-d735-4a37-b430-932b519254ee>

### Fixed

- Fixed `UndefVarError` during full analysis by updating the vendored
  JuliaInterpreter.jl to v0.10.9.
- Fixed source location links in hover content to use comma-delimited format
  (`#L<line>,<character>`) instead of `#L<line>C<character>`. The previous
  format was not correctly parsed by VS Code - the column position was ignored.
  The new format follows VS Code's implementation and works with other LSP
  clients like Sublime Text's LSP plugin.
  Fixes https://github.com/aviatesk/JETLS.jl/issues/281.

## 2025-12-06

- Commit: [`fd5f113`](https://github.com/aviatesk/JETLS.jl/commit/fd5f113)
- Diff: [`c23409d...fd5f113`](https://github.com/aviatesk/JETLS.jl/compare/c23409d...fd5f113)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2025-12-06")'
  ```

### Fixed

- TestRunner code lenses and code actions now properly wait for file cache
  population before being computed.

### Changed

- Updated JuliaSyntax.jl and JuliaLowering to the latest development versions.

## 2025-12-05

- Commit: [`c23409d`](https://github.com/aviatesk/JETLS.jl/commit/c23409d)
- Diff: [`aae52f5...c23409d`](https://github.com/aviatesk/JETLS.jl/compare/aae52f5...c23409d)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2025-12-05")'
  ```

### Changed

- `diagnostic.patterns` from LSP config and file config are now merged instead
  of file config completely overriding LSP config. For patterns with the same
  `pattern` value, file config wins. Patterns unique to either source are preserved.

### Fixed

- Request handlers now wait for file cache to be populated instead of immediately
  returning errors. This fixes "file cache not found" errors that occurred when
  requests arrived before the cache was ready, particularly after opening files.
  (https://github.com/aviatesk/JETLS.jl/issues/273,
   https://github.com/aviatesk/JETLS.jl/issues/274,
   https://github.com/aviatesk/JETLS.jl/issues/327)
- Fixed glob pattern matching for `diagnostic.patterns[].path`: `**` now
  correctly matches zero or more directory levels (e.g., `test/**/*.jl` matches
  `test/testfile.jl`), and wildcards no longer match hidden files/directories.
  (https://github.com/aviatesk/JETLS.jl/pull/359)
- `.JETLSConfig.toml` is now only recognized at the workspace root.
  Previously, config files in subdirectories were also loaded, which was
  inconsistent with [the documentation](https://aviatesk.github.io/JETLS.jl/release/configuration/#config/file-based-config).
- Clean up methods from previous analysis modules after re-analysis to prevent
  stale overload methods from appearing in signature help or completions.

### Internal

- Added heap snapshot profiling support. Create a `.JETLSProfile` file in the
  workspace root to trigger a heap snapshot. The snapshot is saved as
  `JETLS_YYYYMMDD_HHMMSS.heapsnapshot` and can be analyzed using Chrome DevTools.
  See [DEVELOPMENT.md's Profiling](./DEVELOPMENT.md#profiling) section for details.

## 2025-12-02

- Commit: [`aae52f5`](https://github.com/aviatesk/JETLS.jl/commit/aae52f5)
- Diff: [`f9b2c2f...aae52f5`](https://github.com/aviatesk/JETLS.jl/compare/f9b2c2f...aae52f5)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2025-12-02")'
  ```

### Added

- Added support for LSP `initializationOptions` with the experimental
  `n_analysis_workers` option for configuring concurrent analysis worker tasks.
  See [Initialization options](https://aviatesk.github.io/JETLS.jl/release/launching/#init-options)
  for details.

### Changed

- Parallelized signature analysis phase using `Threads.@spawn`, leveraging the
  thread-safe inference pipeline introduced in Julia v1.12. This parallelization
  happens automatically when Julia is started with multiple threads, independent
  of the newly added `n_analysis_workers` initialization option.
  With 4 threads (`--threads=4,2` specifically), first-time analysis of CSV.jl
  improved from 30s to 18s (~1.7x faster), and JETLS.jl itself from 154s to 36s
  (~4.3x faster).

### Fixed

- Fixed handling of messages received before the initialize request per
  [LSP 3.17 specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#initialize).
- Fixed progress indicator not being cleaned up when analysis throws an error.

## 2025-11-30

- Commit: [`f9b2c2f`](https://github.com/aviatesk/JETLS.jl/commit/f9b2c2f)
- Diff: [`eda08b5...f9b2c2f`](https://github.com/aviatesk/JETLS.jl/compare/eda08b5...f9b2c2f)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2025-11-30")'
  ```

### Added

- JETLS now automatically runs `Pkg.resolve()` and `Pkg.instantiate()` for
  packages that have not been instantiated yet (e.g., freshly cloned repositories).
  This allows full analysis to work immediately upon opening such packages.
  When no manifest file exists, JETLS first creates a
  [versioned manifest](https://pkgdocs.julialang.org/v1/toml-files/#Different-Manifests-for-Different-Julia-versions)
  (e.g., `Manifest-v1.12.toml`).
  This behavior is controlled by the `full_analysis.auto_instantiate`
  configuration option (default: `true`). Set it to `false` to disable.
- When `full_analysis.auto_instantiate` is disabled, JETLS now checks if the
  environment is instantiated and warns the user if not.

### Fixed

- Fixed error when receiving notifications after shutdown request. The server
  now silently ignores notifications instead of causing errors from invalid
  property access (which is not possible for notifications).
- Fixed race condition in package environment detection when multiple files are
  opened simultaneously. Added global lock to `activate_do` to serialize
  environment switching operations. This fixes spurious "Failed to identify
  package environment" warnings.
- Fixed document highlight and rename not working for function parameters
  annotated with `@nospecialize` or `@specialize`.

### Internal

- Fixed Revise integration in development mode. The previous approach of
  dynamically loading Revise via `Base.require` didn't work properly because
  Revise assumes it's loaded from a REPL session. Revise is now a direct
  dependency that's conditionally loaded at compile time based on the
  `JETLS_DEV_MODE` flag.
- Significantly refactored the full-analysis pipeline implementation. Modified
  the full-analysis pipeline behavior to output more detailed logs when
  `JETLS_DEV_MODE` is enabled.

## 2025-11-28

- Commit: [`eda08b5`](https://github.com/aviatesk/JETLS.jl/commit/eda08b5)
- Diff: [`6ec51e1...eda08b5`](https://github.com/aviatesk/JETLS.jl/compare/6ec51e1...eda08b5)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2025-11-28")'
  ```

### Changed

- Pinned installation now uses release tags (`rev="YYYY-MM-DD"`) instead of
  branch names (`rev="releases/YYYY-MM-DD"`). The `releases/YYYY-MM-DD` branches
  will be deleted after merging since `[sources]` entries reference commit
  SHAs directly. Existing release branches (`releases/2025-11-24` through
  `releases/2025-11-27`) will be kept until the end of December 2025 for
  backward compatibility.

### Fixed

- Fixed false `lowering/macro-expansion-error` diagnostics appearing before
  initial full-analysis completes. These diagnostics are now skipped until
  module context is available, then refreshed via `workspace/diagnostic/refresh`.
  Fixes https://github.com/aviatesk/JETLS.jl/issues/279 and
  https://github.com/aviatesk/JETLS.jl/issues/290.
  (https://github.com/aviatesk/JETLS.jl/pull/333)

### Removed

- Removed the deprecated `runserver.jl` script. Users should use the `jetls`
  executable app instead. See the [2025-11-24](https://github.com/aviatesk/JETLS.jl/blob/master/CHANGELOG.md#2025-11-24)
  release notes for migration details.

## 2025-11-27

- Commit: [`6ec51e1`](https://github.com/aviatesk/JETLS.jl/commit/6ec51e1)
- Diff: [`6bc34f1...6ec51e1`](https://github.com/aviatesk/JETLS.jl/compare/6bc34f1...6ec51e1)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2025-11-27")'
  ```

### Added

- Added `--version` (`-v`) option to the `jetls` CLI to display version information.
  The `--help` output now also includes the version. Version is stored in the
  `JETLS_VERSION` file and automatically updated during releases.
- Automatic GitHub Release creation when release PRs are merged.
  You can view releases at <https://github.com/aviatesk/JETLS.jl/releases>.
  The contents are and will be extracted from this CHANGELOG.md.

### Changed

- Updated CodeTracking.jl, LoweredCodeUtils and JET.jl dependencies to the
  latest development versions.

### Internal

- Automation for release process: `scripts/prepare-release.sh` automates
  release branch creation, dependency vendoring, and PR creation.
- Automatic CHANGELOG.md updates via CI when release PRs are merged.

## 2025-11-26

- Commit: [`6bc34f1`](https://github.com/aviatesk/JETLS.jl/commit/6bc34f1)
- Diff: [`2be0cff...6bc34f1`](https://github.com/aviatesk/JETLS.jl/compare/2be0cff...6bc34f1)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2025-11-26")'
  ```

### Changed

- Updated JuliaSyntax.jl and JuliaLowering.jl dependencies to the latest
  development versions.
- Updated documentation deployment to use `release` as the default version.
  The documentation now has two versions in the selector: `release` (stable) and
  `dev` (development). The root URL redirects to `/release/` by default.
  The release documentation index page shows the release date extracted from
  commit messages.

## 2025-11-25

- Commit: [`2be0cff`](https://github.com/aviatesk/JETLS.jl/commit/2be0cff)
- Diff: [`fac4eaf...2be0cff`](https://github.com/aviatesk/JETLS.jl/compare/fac4eaf...2be0cff)
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2025-11-25")'
  ```

### Added

- Added CI workflow for testing the vendored release environment.
  This validates that changes to master don't break the release branch.
  (https://github.com/aviatesk/JETLS.jl/pull/321)
- Added CI workflow for the `release` branch with tests and documentation deployment.
  Documentation for the `release` branch is now available at <https://aviatesk.github.io/JETLS.jl/release/>.
  (https://github.com/aviatesk/JETLS.jl/pull/321)

### Fixed

- Fixed vendoring script to remove unused weakdeps and extensions from vendored
  packages. These could interact with user's package environment unexpectedly.
  Extensions that are actually used by JETLS are preserved with updated UUIDs.
  Fixes https://github.com/aviatesk/JETLS.jl/issues/312.
  (https://github.com/aviatesk/JETLS.jl/pull/320)

## 2025-11-24

- Commit: [`fac4eaf`](https://github.com/aviatesk/JETLS.jl/commit/fac4eaf)

### Changed / Breaking

- Implemented environment isolation via dependency vendoring to prevent conflicts
  between JETLS dependencies and packages being analyzed.
  All JETLS dependencies are now vendored with rewritten UUIDs in the `release`
  branch, allowing JETLS to maintain its own isolated copies of dependencies.
  This resolves issues where version conflicts between JETLS and analyzed
  packages would prevent analysis.
  Users should install JETLS from the `release` branch using
  `Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="release")`.
  (https://github.com/aviatesk/JETLS.jl/pull/314)
  - For developers:
    See <https://github.com/aviatesk/JETLS.jl/blob/master/DEVELOPMENT.md#release-process>
    for details on the release process.
- Migrated the JETLS entry point from the `runserver.jl` script to the `jetls`
  [executable app](https://pkgdocs.julialang.org/dev/apps/) defined by JETLS.jl itself.
  This significantly changes how JETLS is installed and launched,
  while the new methods are generally simpler:
  (https://github.com/aviatesk/JETLS.jl/pull/314)
  - Installation: Install the `jetls` executable app using:
    ```bash
    julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="release")'
    ```
    This installs the executable to `~/.julia/bin/jetls`.
    Make sure `~/.julia/bin` is in your `PATH`.
  - Updating: Update JETLS to the latest version by re-running the installation command:
    ```bash
    julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="release")'
    ```
  - Launching: Language clients should launch JETLS using the `jetls` executable with appropriate options.
    See <https://aviatesk.github.io/JETLS.jl/release/launching/> for detailed launch options.
  - The VSCode language client `jetls-client` and Zed extension `aviatesk/zed-julia` has been updated accordingly.
- Changed diagnostic configuration schema from `[diagnostic.codes]` to
  `[[diagnostic.patterns]]` for more flexible pattern matching.
  (https://github.com/aviatesk/JETLS.jl/pull/299)
- Renamed configuration section from `[diagnostics]` to `[diagnostic]` for consistency.
  (https://github.com/aviatesk/JETLS.jl/pull/299)

### Added

- Added configurable diagnostic serveirty support with hierarchical diagnostic
  codes in `"category/kind"` format.
  Users can now control which diagnostics are displayed and their severity
  levels through fine-grained configuration.
  (https://github.com/aviatesk/JETLS.jl/pull/298)
- Added pattern-based diagnostic configuration supporting message-based
  matching in addition to code-based matching.
  Supports both `literal` and `regex` patterns with a four-tier priority system.
  (https://github.com/aviatesk/JETLS.jl/pull/299)
- Added file path-based filtering for diagnostic patterns.
  Users can specify glob patterns (e.g., `"test/**/*.jl"`) to apply diagnostic
  configurations to specific files or directories.
  (https://github.com/aviatesk/JETLS.jl/pull/313)
- Added LSP `codeDescription` implementation with clickable documentation links
  for diagnostics. (https://github.com/aviatesk/JETLS.jl/pull/298)
- Added this change log. (https://github.com/aviatesk/JETLS.jl/pull/316)

### Fixed

- Fixed UTF-8 position encoding to use byte offsets instead of character counts.
  This resolves misalignment issues in UTF-8-based editors like Helix while maintaining compatibility with UTF-16 editors like VS Code.
  (https://github.com/aviatesk/JETLS.jl/pull/306)
