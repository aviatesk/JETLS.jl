# CHANGELOG

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

> [!warning]
> JETLS has not been officially released yet, and therefore does not follow a formal versioning policy.
> This change log currently documents major changes based on the dates they were added.

## Unreleased

> [!note]
>
> - Commit: [`HEAD`](https://github.com/aviatesk/JETLS.jl/commit/HEAD)

### Added

- Added CI workflow for testing the vendored release environment.
  This validates that changes to master don't break the release branch.
  (aviatesk/JETLS.jl#321)
- Added CI workflow for the `release` branch with tests and documentation deployment.
  Documentation for the `release` branch is now available at <https://aviatesk.github.io/JETLS.jl/release/>.
  (aviatesk/JETLS.jl#321)

### Fixed

- Fixed vendoring script to remove unused weakdeps and extensions from vendored
  packages. These could interact with user's package environment unexpectedly.
  Extensions that are actually used by JETLS are preserved with updated UUIDs.
  Fixes aviatesk/JETLS.jl#312. (aviatesk/JETLS.jl#320)

## [2025-11-24]

[2025-11-24]: https://github.com/aviatesk/JETLS.jl/commit/db47b8b

> [!note]
>
> - Commit: [`db47b8b`](https://github.com/aviatesk/JETLS.jl/commit/db47b8b)

### Changed / Breaking

- Implemented environment isolation via dependency vendoring to prevent conflicts
  between JETLS dependencies and packages being analyzed.
  All JETLS dependencies are now vendored with rewritten UUIDs in the `release`
  branch, allowing JETLS to maintain its own isolated copies of dependencies.
  This resolves issues where version conflicts between JETLS and analyzed
  packages would prevent analysis.
  Users should install JETLS from the `release` branch using
  `Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="release")`. (aviatesk/JETLS.jl#314)
  - For developers:
    See <https://github.com/aviatesk/JETLS.jl/blob/master/DEVELOPMENT.md#release-process>
    for details on the release process.
- Migrated the JETLS entry point from the `runserver.jl` script to the `jetls`
  [executable app](https://pkgdocs.julialang.org/dev/apps/) defined by JETLS.jl itself.
  This significantly changes how JETLS is installed and launched,
  while the new methods are generally simpler: (aviatesk/JETLS.jl#314)
  - Installation: Install the `jetls` executable app using:
    ```bash
    julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="release")'
    ```
    This installs the executable to `~/.julia/bin/` (as `jetls` on Unix-like systems, `jetls.exe` on Windows).
    Make sure `~/.julia/bin` is in your `PATH`.
  - Updating: Update JETLS to the latest version using:
    ```bash
    julia -e 'using Pkg; Pkg.Apps.update("JETLS")'
    ```
  - Launching: Language clients should launch JETLS using the `jetls` executable with appropriate options.
    See <https://aviatesk.github.io/JETLS.jl/dev/launching/> for detailed launch options.
  - The VSCode language client `jetls-client` and Zed extension `aviatesk/zed-julia` has been updated accordingly.
- Changed diagnostic configuration schema from `[diagnostic.codes]` to `[[diagnostic.patterns]]` for more flexible pattern matching. (aviatesk/JETLS.jl#299)
- Renamed configuration section from `[diagnostics]` to `[diagnostic]` for consistency. (aviatesk/JETLS.jl#299)

### Added

- Added configurable diagnostic serveirty support with hierarchical diagnostic
  codes in `"category/kind"` format.
  Users can now control which diagnostics are displayed and their severity
  levels through fine-grained configuration.
  (aviatesk/JETLS.jl#298)
- Added pattern-based diagnostic configuration supporting message-based
  matching in addition to code-based matching.
  Supports both `literal` and `regex` patterns with a four-tier priority system.
  (aviatesk/JETLS.jl#299)
- Added file path-based filtering for diagnostic patterns.
  Users can specify glob patterns (e.g., `"test/**/*.jl"`) to apply diagnostic
  configurations to specific files or directories.
  (aviatesk/JETLS.jl#313)
- Added LSP `codeDescription` implementation with clickable documentation links
  for diagnostics. (aviatesk/JETLS.jl#298)
- Added this change log. (aviatesk/JETLS.jl#316)

### Fixed

- Fixed UTF-8 position encoding to use byte offsets instead of character counts.
  This resolves misalignment issues in UTF-8-based editors like Helix while maintaining compatibility with UTF-16 editors like VS Code.
  (aviatesk/JETLS.jl#306)
