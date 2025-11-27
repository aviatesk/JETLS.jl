# CHANGELOG

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

> [!note]
> JETLS uses date-based versioning (`YYYY-MM-DD`) rather than semantic versioning,
> as it is not registered in General due to environment isolation requirements.
>
> Each dated section below corresponds to a release that can be installed via
> `Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="YYYY-MM-DD")`

## Unreleased

- Commit: [`HEAD`](https://github.com/aviatesk/JETLS.jl/commit/HEAD)
- Diff: [`eda08b5...HEAD`](https://github.com/aviatesk/JETLS.jl/compare/eda08b5...HEAD)

### Fixed

- Fixed Revise integration in development mode. The previous approach of
  dynamically loading Revise via `Base.require` didn't work properly because
  Revise assumes it's loaded from a REPL session. Revise is now a direct
  dependency that's conditionally loaded at compile time based on the
  `JETLS_DEV_MODE` flag.
- Fixed error when receiving notifications after shutdown request. The server
  now silently ignores notifications instead of causing errors from invalid
  property access (which is not possible for notifications).
- Fixed race condition in package environment detection when multiple files are
  opened simultaneously. Added global lock to `activate_do` to serialize
  environment switching operations. This fixes spurious "Failed to identify
  package environment" warnings.

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
  Fixes aviatesk/JETLS.jl#279 and aviatesk/JETLS.jl#290. (aviatesk/JETLS.jl#333)

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
  (aviatesk/JETLS.jl#321)
- Added CI workflow for the `release` branch with tests and documentation deployment.
  Documentation for the `release` branch is now available at <https://aviatesk.github.io/JETLS.jl/release/>.
  (aviatesk/JETLS.jl#321)

### Fixed

- Fixed vendoring script to remove unused weakdeps and extensions from vendored
  packages. These could interact with user's package environment unexpectedly.
  Extensions that are actually used by JETLS are preserved with updated UUIDs.
  Fixes aviatesk/JETLS.jl#312. (aviatesk/JETLS.jl#320)

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
  - Updating: Update JETLS to the latest version by re-running the installation command:
    ```bash
    julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="release")'
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
