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
- Diff: [`b61b6fa...HEAD`](https://github.com/aviatesk/JETLS.jl/compare/b61b6fa...HEAD)

### Announcement

> [!note]
> To install or update JETLS to the latest version, run:
> ```bash
> julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="release")'
> ```

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

### Fixed

- Fixed method overwrite detection to handle both `Core.CodeInfo` and `Expr`
  source types, making the analysis more robust. (https://github.com/aviatesk/JETLS.jl/pull/421)
- Fixed `toplevel/abstract-field` diagnostic to report correct field locations
  for structs with `<:` subtyping syntax and `const` field modifiers. (https://github.com/aviatesk/JETLS.jl/pull/422)

## 2025-12-31

- Commit: [`b61b6fa`](https://github.com/aviatesk/JETLS.jl/commit/b61b6fa)
- Diff: [`afc5137...b61b6fa`](https://github.com/aviatesk/JETLS.jl/compare/afc5137...b61b6fa)

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

### Added

- Jupyter notebook support: JETLS now provides language features for Julia code
  cells in Jupyter notebooks. As shown in the demo below, all code cells are
  analyzed together as a single source, as if the notebook were a single Julia
  script. JETLS is aware of all cells, so features like go-to-definition,
  completions, and diagnostics work across cells just as they would in a
  regular Julia script.

  > JETLS × notebook LSP demo

  https://github.com/user-attachments/assets/b5bb5201-d735-4a37-b430-932b519254ee

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

### Fixed

- TestRunner code lenses and code actions now properly wait for file cache
  population before being computed.

### Changed

- Updated JuliaSyntax.jl and JuliaLowering to the latest development versions.

## 2025-12-05

- Commit: [`c23409d`](https://github.com/aviatesk/JETLS.jl/commit/c23409d)
- Diff: [`aae52f5...c23409d`](https://github.com/aviatesk/JETLS.jl/compare/aae52f5...c23409d)

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
