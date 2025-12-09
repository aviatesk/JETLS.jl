# CHANGELOG

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

- Commit: [`HEAD`](https://github.com/aviatesk/JETLS.jl/commit/HEAD)
- Diff: [`87c4b3f...HEAD`](https://github.com/aviatesk/JETLS.jl/compare/87c4b3f...HEAD)

## v0.2.6

- Commit: [`87c4b3f`](https://github.com/aviatesk/JETLS.jl/commit/87c4b3f)
- Diff: [`e552f0f...87c4b3f`](https://github.com/aviatesk/JETLS.jl/compare/e552f0f...87c4b3f)

### Fixed

- Fixed Windows support by using `jetls.bat` instead of `jetls.exe` as the
  default executable, and enabling shell spawn mode for batch files.
  Fixes aviatesk/JETLS.jl#339. Thanks to @visr. (aviatesk/JETLS.jl#372)

## v0.2.5

- Commit: [`e552f0f`](https://github.com/aviatesk/JETLS.jl/commit/e552f0f)
- Diff: [`dd21f78...e552f0f`](https://github.com/aviatesk/JETLS.jl/compare/dd21f78...e552f0f)

### Added

- Jupyter notebook support: JETLS now provides language features for Julia code
  cells in Jupyter notebooks. As shown in the demo below, all code cells are
  analyzed together as a single source, as if the notebook were a single Julia
  script. JETLS is aware of all cells, so features like go-to-definition,
  completions, and diagnostics work across cells just as they would in a
  regular Julia script.

  > JETLS × notebook LSP demo

  https://github.com/user-attachments/assets/b5bb5201-d735-4a37-b430-932b519254ee

- Published extension to [Open VSX Registry](https://open-vsx.org/extension/aviatesk/jetls-client)
  for users of VSCode-compatible editors like [Eclipse Theia](https://theia-ide.org/)
  or [Cursor](https://cursor.com/).
- Added `jetls-client.initializationOptions` setting for static server options
  that require a restart to take effect. Currently supports `n_analysis_workers`
  for configuring concurrent analysis worker tasks.
  See <https://aviatesk.github.io/JETLS.jl/release/launching/#init-options> for details.

### Changed

- Updated `vscode-languageclient` to 10.0.0-next.18 to enable pull diagnostics
  support for Jupyter notebook cells.

## v0.2.4

- Commit: [`dd21f78`](https://github.com/aviatesk/JETLS.jl/commit/dd21f78)
- Diff: [`b6d20b6...dd21f78`](https://github.com/aviatesk/JETLS.jl/compare/b6d20b6...dd21f78)

### Added

- Added `jetls-client.settings.full_analysis.auto_instantiate` configuration option
  (default: `true`). When enabled, JETLS automatically runs `Pkg.instantiate()` for
  packages that have not been instantiated yet (e.g., freshly cloned repositories).
  See <https://aviatesk.github.io/JETLS.jl/release/configuration/#config/full_analysis-auto_instantiate>
  for more details. (aviatesk/JETLS.jl#337)

## v0.2.3

- Commit: [`b6d20b6`](https://github.com/aviatesk/JETLS.jl/commit/b6d20b6)
- Diff: [`250188fc...b6d20b6`](https://github.com/aviatesk/JETLS.jl/compare/250188fc...b6d20b6)

### Improved

- Improved error handling when the JETLS executable is not found (ENOENT error).
  The extension now displays a user-friendly error notification with:
  - The command that was attempted
  - The current PATH environment variable
  - A hint to restart VS Code if JETLS is already installed
  - Buttons to install JETLS or view the installation guide
  (aviatesk/JETLS.jl#335)

## v0.2.2

- Commit: [`250188fc`](https://github.com/aviatesk/JETLS.jl/commit/9008d1b)
- Diff: [`34278b3...250188fc`](https://github.com/aviatesk/JETLS.jl/compare/250188fc...9008d1b)

### Fixed

- (Really) fix installation command syntax in the migration commands invoked via
  the extension installation/update notification to use correct `Pkg.Apps.add`
  keyword argument format

## v0.2.1

- Commit: [`250188fc`](https://github.com/aviatesk/JETLS.jl/commit/250188fc)
- Diff: [`34278b3...250188fc`](https://github.com/aviatesk/JETLS.jl/compare/34278b3...250188fc)

### Fixed

- Fixed installation command syntax in documentation and migration notification
  to use correct `Pkg.Apps.add` keyword argument format

## v0.2.0

- Commit: [`34278b3`](https://github.com/aviatesk/JETLS.jl/commit/34278b3)
- Diff: [`b0a4a4c...34278b3`](https://github.com/aviatesk/JETLS.jl/compare/b0a4a4c...34278b3)

> [!warning]
> **Breaking changes**: JETLS installation method has changed significantly.
> You must reinstall JETLS using the new `jetls` executable app.
> See the [installation steps](#installation-steps) below.

### Installation steps

1. Install the `jetls` executable app:
   ```bash
   julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="release")'
   ```
2. Make sure `~/.julia/bin` is in your `PATH`
3. Restart VSCode

### Added

- Added update notification system that prompts users to update the JETLS server
  when the extension is updated.

### Changed

- JETLS launch configuration has been significantly updated with the migration to the `jetls` executable app.
  See <https://aviatesk.github.io/JETLS.jl/release/#Server-installation> for the new installation and configuration guide.
  Most users can complete the migration by installing the `jetls` executable app:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="release")'
  ```
- [JETLS configuration](https://aviatesk.github.io/JETLS.jl/release/configuration/)
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
  For more details, see <https://aviatesk.github.io/JETLS.jl/release/configuration/#config/diagnostic-patterns>.
  (aviatesk/JETLS.jl#313)

### Breaking

- Thread setting for JETLS process should now be set via `jetls-client.executable.threads` option,
  and the previous `jetls-client.juliaThreads` setting has been removed.
- `jetls-client.juliaExecutablePath` and `jetls-client.jetlsDirectory`
  configuration options have been removed in favor of the new `jetls-client.executable` configuration
- `jetls-client.jetlsSettings` has been renamed to `jetls-client.settings`

## v0.1.3

- Commit: [`b0a4a4c`](https://github.com/aviatesk/JETLS.jl/commit/b0a4a4c)
- Diff: [`6ac86f9...b0a4a4c`](https://github.com/aviatesk/JETLS.jl/compare/6ac86f9...b0a4a4c)

### Added

- Added `jetls-client.jetlsSettings.diagnostic` configuration to control
  diagnostic on/off state and severity levels (aviatesk/JETLS.jl#298)

## v0.1.2

- Commit: [`6ac86f9`](https://github.com/aviatesk/JETLS.jl/commit/6ac86f9)
- Diff: [`f199854...6ac86f9`](https://github.com/aviatesk/JETLS.jl/compare/f199854...6ac86f9)

### Added

- Added `jetls-client.jetlsSettings.formatter` configuration to switch formatter
  backend between [Runic](github.com/fredrikekre/Runic.jl) and
  [JuliaFormatter](github.com/fredrikekre/Runic.jl).
  See <https://aviatesk.github.io/JETLS.jl/release/formatting/> for more details.
  (aviatesk/JETLS.jl#284)
- Added support for configuring JETLS through VSCode's `settings.json` file (aviatesk/JETLS.jl#296)

## v0.1.1

- Commit: [`f199854`](https://github.com/aviatesk/JETLS.jl/commit/f199854)
- Diff: [`bc91e4e...f199854`](https://github.com/aviatesk/JETLS.jl/compare/bc91e4e...f199854)

## v0.1.0

- Commit: [`bc91e4e`](https://github.com/aviatesk/JETLS.jl/commit/bc91e4e)

- Initial release
