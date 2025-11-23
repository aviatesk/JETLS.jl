# jetls-client

[![](https://img.shields.io/badge/docs-user_guide-9558B2?logo=julia)](https://aviatesk.github.io/JETLS.jl/dev/)
[![](https://img.shields.io/badge/docs-dev_notes-7C3AED?logo=obsidian)](https://publish.obsidian.md/jetls)

A [VSCode](https://code.visualstudio.com/) client extension for
[JETLS](../README.md).

JETLS is a new language server for [Julia](https://julialang.org/).
JETLS aims to enhance developer productivity by providing advanced static
analysis and seamless integration with the Julia runtime.
By leveraging tooling technologies like
[JET.jl](https://github.com/aviatesk/JET.jl),
[JuliaSyntax.jl](https://github.com/JuliaLang/JuliaSyntax.jl) and
[JuliaLowering.jl](https://github.com/c42f/JuliaLowering.jl),
JETLS aims to offer enhanced language features such as type-sensitive
diagnostic, macro-aware go-to definition and such.

## Getting started

### Requirements

- [VSCode](https://code.visualstudio.com/) v1.96.0 or higher
- [Julia `v"1.12"`](https://julialang.org/downloads) or higher

### Steps

> [!warning]
> The `jetls-client` extension does not bundle JETLS.jl itself. You need to
> install the `jetls` executable separately before using the extension.

1. Install the `jetls` [executable app](https://pkgdocs.julialang.org/dev/apps/),
   which is the main entry point for running JETLS:
   ```bash
   julia -e 'using Pkg; Pkg.Apps.add("https://github.com/aviatesk/JETLS.jl#release")'
   ```
   This will install the `jetls` executable (`jetls.exe` on Windows) to `~/.julia/bin/`.
   Make sure `~/.julia/bin` is available on the `PATH` environment so the `jetls` executable is accessible.
2. Install `jetls-client`:
   - Open VSCode
   - Go to Extensions (Invoke the `View: Show Extensions` command)
   - Search for `"JETLS Client"`
   - Click `Install`
3. Open any Julia file

The extension will automatically use the `jetls` (or `jetls.exe` on Windows)
executable from your `PATH`.

> [!note]
> To update JETLS to the latest version:
>
> ```bash
> julia -e 'using Pkg; Pkg.Apps.update("JETLS")'
> ```
>
> JETLS has not been officially released yet, so there is no versioning policy
> at this time. In the future, you will be able to install specific versions.

### Advanced launching configuration

Most users do not need any further setups beyond the installation steps above.
The following settings are available for advanced use cases:

- `jetls-client.executable`: JETLS executable configuration. Use object form
  `{path, threads}` to customize the installed JETLS executable path or thread
  setting, or array form for a local JETLS checkout
  (default: `{"path": "jetls", "threads": "auto"}`)
- `jetls-client.communicationChannel`: Communication channel for the language
  server. Options: `"auto"` (default), `"pipe"`, `"stdio"`, `"socket"`. See
  [Communication channels](https://aviatesk.github.io/JETLS.jl/dev/launching/#Communication-channels)
  for details
- `jetls-client.socketPort`: Port number for socket communication
  (default: `0` for auto-assign). Only used when `"socket"` communication
  channel is selected

## JETLS Configuration

JETLS behavior (diagnostics, formatting, etc.) can be configured through VSCode's
`settings.json` file using the `jetls-client.settings` section.

### Example configuration

Add the following to your `.vscode/settings.json` (project specific setting file)
or global user settings:

```jsonc
{
  "jetls-client.settings": {
    "full_analysis": {
      "debounce": 1.0
    },
    "formatter": "Runic",
    "diagnostic": {
      "patterns": [
        // Disable all diagnostics for test code
        {
          "pattern": ".*",
          "match_by": "code",
          "match_type": "regex",
          "severity": "off",
          "path": "test//*.jl"
        }
      ]
    }
  }
}
```

### Available settings

- `jetls-client.settings.full_analysis.debounce`: Debounce time in seconds
  before triggering full analysis after a document change (default: `1.0`)
- `jetls-client.settings.formatter`: Formatter configuration. Can be a preset
  name (`"Runic"` or `"JuliaFormatter"`) or a custom formatter object
  (default: `"Runic"`)
- `jetls-client.settings.diagnostic.enabled`: Enable or disable all JETLS
  diagnostics (default: `true`)
- `jetls-client.settings.diagnostic.patterns`: Fine-grained control over
  diagnostics through pattern matching. Each pattern supports `pattern`,
  `match_by` (`"code"` or `"message"`), `match_type` (`"literal"` or `"regex"`),
  `severity`, and optional `path` (glob pattern) fields
- `jetls-client.settings.testrunner.executable`: Path to the TestRunner.jl
  executable (default: `"testrunner"` or `"testrunner.exe"` on Windows)

For detailed configuration options and examples, see the
[Configuration documentation](https://aviatesk.github.io/JETLS.jl/dev/configuration/).

## License

MIT License. See [LICENSE.md](./LICENSE.md) for details.
