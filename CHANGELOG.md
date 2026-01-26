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
- Diff: [`9c00dfe...HEAD`](https://github.com/aviatesk/JETLS.jl/compare/9c00dfe...HEAD)

### Announcement

> [!warning]
> JETLS currently has a known memory leak issue where memory usage grows with
> each re-analysis (https://github.com/aviatesk/JETLS.jl/issues/357).
> As a temporary workaround, you can disable full-analysis for specific files
> using the `analysis_overrides`
> [initialization option](https://aviatesk.github.io/JETLS.jl/release/launching/#init-options):
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
> This disables analysis for matched files. Basic features like completion still
> might work, but most LSP features will be unfunctional.
> Note that `analysis_overrides` is provided as a temporary workaround and may
> be removed or changed at any time. A proper fix is being worked on.

### Added

- Added reference count code lens for top-level symbols (functions, structs,
  constants, abstract types, primitive types, modules). When enabled, a code
  lens showing "N references" appears above each symbol definition. Clicking it
  opens the references panel. This feature is opt-in and can be enabled via
  [`code_lens.references`](https://aviatesk.github.io/JETLS.jl/release/configuration/#config/code_lens-references)
  configuration.

- Added [`code_lens.testrunner`](https://aviatesk.github.io/JETLS.jl/release/configuration/#config/code_lens-testrunner)
  configuration option to enable or disable TestRunner code lenses. Some editors
  (e.g., Zed) display code lenses as code actions, causing duplication.
  The [aviatesk/zed-julia](https://github.com/aviatesk/zed-julia) extension
  automatically defaults this to `false`.

- Added document symbol support for `if` and `@static if` blocks. These blocks
  now appear in the document outline as `SymbolKind.Namespace` symbols, with
  all definitions from `if`/`elseif`/`else` branches flattened as children.

### Changed

- Namespace symbols (`if`/`let`/`for`/`while`/`@static if` blocks) are now
  excluded from workspace symbol search. These symbols exist only to provide
  hierarchical structure in the document outline, not to represent actual
  definitions.

- `textDocument/diagnostic` now supports cancellation, avoiding to compute
  staled diagnostics (https://github.com/aviatesk/JETLS.jl/pull/524)

### Fixed

- Lowering diagnostics no longer report issues in macro-generated code that
  users cannot control. User-written identifiers processed by new-style macros
  are still reported, but old-style macros are not yet supported due to
  JuliaLowering limitations. (https://github.com/aviatesk/JETLS.jl/issues/522)

- Fixed potential segfault on server exit by implementing graceful shutdown of
  worker tasks. All `Threads.@spawn`ed tasks are now properly terminated before
  the server exits. (xref: https://github.com/JuliaLang/julia/issues/32983, https://github.com/aviatesk/JETLS.jl/pull/523)

- Fixed thread-safety issue with cached syntax trees. Multiple threads accessing
  the same cached tree during lowering could cause data races and segfaults.
  Cached trees are now copied before use. (https://github.com/aviatesk/JETLS.jl/pull/525)

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

- Added [`diagnostic.all_files`](https://aviatesk.github.io/JETLS.jl/release/configuration/#config/diagnostic-all_files)
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
  julia -e 'using Pkg; Pkg.Apps.add(url="https://github.com/aviatesk/TestRunner.jl#release")'
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
