# CHANGELOG

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

> [!note]
>
> - Commit: [`HEAD`](https://github.com/aviatesk/JETLS.jl/commit/HEAD)

## [v0.2.0]

[v0.2.0]: https://github.com/aviatesk/JETLS.jl/compare/b0a4a4c...HEAD

> [!note]
>
> - Diff: [`b0a4a4c...HEAD`](https://github.com/aviatesk/JETLS.jl/compare/b0a4a4c...HEAD)

> [!warning]
> **Breaking changes**: JETLS installation method has changed significantly.
> You must reinstall JETLS using the new `jetls` executable app.
> See the [installation steps](#installation-steps) below.

### Installation steps

1. Install the `jetls` executable app:
   ```bash
   julia -e 'using Pkg; Pkg.Apps.add("https://github.com/aviatesk/JETLS.jl#release")'
   ```
2. Make sure `~/.julia/bin` is in your `PATH`
3. Restart VSCode

### Changed

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

### Breaking

- Thread setting for JETLS process should now be set via `jetls-client.executable.threads` option,
  and the previous `jetls-client.juliaThreads` setting has been removed.
- `jetls-client.juliaExecutablePath` and `jetls-client.jetlsDirectory`
  configuration options have been removed in favor of the new `jetls-client.executable` configuration
- `jetls-client.jetlsSettings` has been renamed to `jetls-client.settings`

## [v0.1.3]

[v0.1.3]: https://github.com/aviatesk/JETLS.jl/compare/6ac86f9...b0a4a4c

> [!note]
>
> - Commit: [`b0a4a4c`](https://github.com/aviatesk/JETLS.jl/commit/b0a4a4c)
> - Diff: [`6ac86f9...b0a4a4c`](https://github.com/aviatesk/JETLS.jl/compare/6ac86f9...b0a4a4c)

### Added

- Added `jetls-client.jetlsSettings.diagnostic` configuration to control
  diagnostic on/off state and severity levels (aviatesk/JETLS.jl#298)

## [v0.1.2]

[v0.1.2]: https://github.com/aviatesk/JETLS.jl/compare/f199854...6ac86f9

> [!note]
>
> - Commit: [`6ac86f9`](https://github.com/aviatesk/JETLS.jl/commit/6ac86f9)
> - Diff: [`f199854...6ac86f9`](https://github.com/aviatesk/JETLS.jl/compare/f199854...6ac86f9)

### Added

- Added `jetls-client.jetlsSettings.formatter` configuration to switch formatter
  backend between [Runic](github.com/fredrikekre/Runic.jl) and
  [JuliaFormatter](github.com/fredrikekre/Runic.jl).
  See <https://aviatesk.github.io/JETLS.jl/dev/formatting/> for more details.
  (aviatesk/JETLS.jl#284)
- Added support for configuring JETLS through VSCode's `settings.json` file (aviatesk/JETLS.jl#296)

## [v0.1.1]

[v0.1.1]: https://github.com/aviatesk/JETLS.jl/compare/bc91e4e...f199854

> [!note]
>
> - Commit: [`f199854`](https://github.com/aviatesk/JETLS.jl/commit/f199854)
> - Diff: [`bc91e4e...f199854`](https://github.com/aviatesk/JETLS.jl/compare/bc91e4e...f199854)

## [v0.1.0]

[v0.1.0]: https://github.com/aviatesk/JETLS.jl/commit/bc91e4e

> [!note]
>
> - Commit: [`bc91e4e`](https://github.com/aviatesk/JETLS.jl/commit/bc91e4e)

- Initial release
