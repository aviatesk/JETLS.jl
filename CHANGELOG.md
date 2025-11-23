# CHANGELOG

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## JETLS.jl

This section tracks the major changes to JETLS.jl, the language server implementation.

> [!warning]
> JETLS has not been officially released yet, and therefore does not follow a formal versioning policy.
> This change log currently documents major changes based on the dates they were added.

### Unreleased

> [!note]
>
> - Commit: [`HEAD`](https://github.com/aviatesk/JETLS.jl/commit/HEAD)

### [2025-11-24]

[2025-11-24]: https://github.com/aviatesk/JETLS.jl/commit/db47b8b

> [!note]
>
> - Commit: [`db47b8b`](https://github.com/aviatesk/JETLS.jl/commit/db47b8b)

#### Changed / Breaking

- Implemented environment isolation via dependency vendoring to prevent conflicts
  between JETLS dependencies and packages being analyzed.
  All JETLS dependencies are now vendored with rewritten UUIDs in the `release`
  branch, allowing JETLS to maintain its own isolated copies of dependencies.
  This resolves issues where version conflicts between JETLS and analyzed
  packages would prevent analysis.
  Users should install JETLS from the `release` branch using
  `Pkg.Apps.add("https://github.com/aviatesk/JETLS.jl#release")`. (aviatesk/JETLS.jl#314)
  - For developers:
    See <https://github.com/aviatesk/JETLS.jl/blob/master/DEVELOPMENT.md#release-process>
    for details on the release process.
- Migrated the JETLS entry point from the `runserver.jl` script to the `jetls`
  [executable app](https://pkgdocs.julialang.org/dev/apps/) defined by JETLS.jl itself.
  This significantly changes how JETLS is installed and launched,
  while the new methods are generally simpler: (aviatesk/JETLS.jl#314)
  - Installation: Install the `jetls` executable app using:
    ```bash
    julia -e 'using Pkg; Pkg.Apps.add("https://github.com/aviatesk/JETLS.jl#release")'
    ```
    This installs the executable to `~/.julia/bin/` (as `jetls` on Unix-like systems, `jetls.exe` on Windows).
    Make sure `~/.julia/bin` is in your `PATH`.
  - Updating: Update JETLS to the latest version using:
    ```bash
    julia -e 'using Pkg; Pkg.Apps.update("JETLS")'
    ```
  - Launching: Language clients should launch JETLS using the `jetls` executable with appropriate options.
    See <https://aviatesk.github.io/JETLS.jl/dev/launching/> for detailed launch options.
  - The VSCode language client `jetls-client` has been updated accordingly.
- Changed diagnostic configuration schema from `[diagnostic.codes]` to `[[diagnostic.patterns]]` for more flexible pattern matching. (aviatesk/JETLS.jl#299)
- Renamed configuration section from `[diagnostics]` to `[diagnostic]` for consistency. (aviatesk/JETLS.jl#299)

#### Added

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

#### Fixed

- Fixed UTF-8 position encoding to use byte offsets instead of character counts.
  This resolves misalignment issues in UTF-8-based editors like Helix while maintaining compatibility with UTF-16 editors like VS Code.
  (aviatesk/JETLS.jl#306)

## `jetls-client`

This section tracks the major changes to `jetls-client`,
a VSCode language client extension for JETLS.

### Unreleased

> [!note]
>
> - Commit: [`HEAD`](https://github.com/aviatesk/JETLS.jl/commit/HEAD)
> - Diff: [`b0a4a4c...HEAD`](https://github.com/aviatesk/JETLS.jl/compare/b0a4a4c...HEAD)

#### Changed

- JETLS launch configuration has been significantly updated with the migration to the `jetls` executable app.
  See <https://aviatesk.github.io/JETLS.jl/dev/#Getting-started> for the new installation and configuration guide.
  Most users can complete the migration by installing the `jetls` executable app:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add("https://github.com/aviatesk/JETLS.jl#release")'
  ```
- [JETLS configuration](https://aviatesk.github.io/JETLS.jl/dev/configuration/)
  should now be set with `jetls-client.settings` section,
  not with `jetls-client.jetlsSettings`.
- Added detailed markdown descriptions for all configuration options.
  These descriptions are displayed in the VSCode settings UI and as hover
  tooltips when editing `settings.json`
- New `jetls-client.executable` configuration option that supports both standard
  installation (object form with `path` and `threads` properties)
  and local JETLS checkout (array form with full command)
- Added support for applying diagnostic configuration to specific files only by
  specifying glob patterns in the `path` field of
  `jetls-client.settings.diagnostic.patterns`.
  For more details, see <https://aviatesk.github.io/JETLS.jl/dev/configuration/#config/diagnostic-patterns>.
  (aviatesk/JETLS.jl#313)

<!--- Added update notification system that prompts users to update the JETLS server when the extension is updated-->

#### Breaking

- Thread setting for JETLS process should now be set via `jetls-client.executable.threads` option,
  and the previous `jetls-client.juliaThreads` setting has been removed.
- `jetls-client.juliaExecutablePath` and `jetls-client.jetlsDirectory`
  configuration options have been removed in favor of the new `jetls-client.executable` configuration
- `jetls-client.jetlsSettings` has been renamed to `jetls-client.settings`

### [v0.1.3]

[v0.1.3]: https://github.com/aviatesk/JETLS.jl/compare/6ac86f9...b0a4a4c

> [!note]
>
> - Commit: [`b0a4a4c`](https://github.com/aviatesk/JETLS.jl/commit/b0a4a4c)
> - Diff: [`6ac86f9...b0a4a4c`](https://github.com/aviatesk/JETLS.jl/compare/6ac86f9...b0a4a4c)

#### Added

- Added `jetls-client.jetlsSettings.diagnostic` configuration to control
  diagnostic on/off state and severity levels (aviatesk/JETLS.jl#298)

### [v0.1.2]

[v0.1.2]: https://github.com/aviatesk/JETLS.jl/compare/f199854...6ac86f9

> [!note]
>
> - Commit: [`6ac86f9`](https://github.com/aviatesk/JETLS.jl/commit/6ac86f9)
> - Diff: [`f199854...6ac86f9`](https://github.com/aviatesk/JETLS.jl/compare/f199854...6ac86f9)

#### Added

- Added `jetls-client.jetlsSettings.formatter` configuration to switch formatter
  backend between [Runic](github.com/fredrikekre/Runic.jl) and
  [JuliaFormatter](github.com/fredrikekre/Runic.jl).
  See <https://aviatesk.github.io/JETLS.jl/dev/formatting/> for more details.
  (aviatesk/JETLS.jl#284)
- Added support for configuring JETLS through VSCode's `settings.json` file (aviatesk/JETLS.jl#296)

### [v0.1.1]

[v0.1.1]: https://github.com/aviatesk/JETLS.jl/compare/bc91e4e...f199854

> [!note]
>
> - Commit: [`f199854`](https://github.com/aviatesk/JETLS.jl/commit/f199854)
> - Diff: [`bc91e4e...f199854`](https://github.com/aviatesk/JETLS.jl/compare/bc91e4e...f199854)

### [v0.1.0]

[v0.1.0]: https://github.com/aviatesk/JETLS.jl/commit/bc91e4e

> [!note]
>
> - Commit: [`bc91e4e`](https://github.com/aviatesk/JETLS.jl/commit/bc91e4e)

- Initial release
