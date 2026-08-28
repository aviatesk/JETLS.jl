# jetls-client

[![](https://img.shields.io/badge/docs-user_guide-9558B2?logo=julia)](https://aviatesk.github.io/JETLS.jl/release/)
[![](https://img.shields.io/badge/docs-dev_notes-7C3AED?logo=obsidian)](https://publish.obsidian.md/jetls)
[![](https://github.com/aviatesk/JETLS.jl/actions/workflows/jetls-client.yml/badge.svg)](https://github.com/aviatesk/JETLS.jl/actions/workflows/jetls-client.yml)

A [VSCode](https://code.visualstudio.com/) client extension for
[JETLS](../README.md).

JETLS is a new language server for [Julia](https://julialang.org/).
JETLS aims to enhance developer productivity by providing advanced static
analysis and seamless integration with the Julia runtime.
By leveraging tooling technologies like
[JET.jl](https://github.com/aviatesk/JET.jl),
[JuliaSyntax.jl](https://github.com/JuliaLang/julia/tree/master/JuliaSyntax) and
[JuliaLowering.jl](https://github.com/JuliaLang/julia/tree/master/JuliaLowering),
JETLS aims to offer enhanced language features such as type-sensitive
diagnostic, macro-aware go-to definition and such.

> [!note]
> JETLS.jl is not integrated with the [`julia-vscode` extension](https://www.julia-vscode.org/) yet.
> To use JETLS from VSCode, install this `jetls-client` extension.
> While we generally recommend disabling `julia-vscode` when using `jetls-client`,
> this is not required; you can use both `julia-vscode` and `jetls-client`
> in the same VSCode session.
> However, since the LSP features provided by JETLS.jl differ in both type and quality
> from those provided by `julia-vscode`'s language server backend
> ([LanguageServer.jl](https://github.com/julia-vscode/LanguageServer.jl)),
> you may encounter confusing situations where, for example, completion candidates
> are provided from different backends.

## Requirements

- [VSCode](https://code.visualstudio.com/) v1.96.0 or higher
- [Julia](https://julialang.org/downloads) v1.12.2 through 1.13.x, with
  the `julia` command available on `PATH`

JETLS does not support Julia 1.12.1 or earlier, nor Julia 1.14+/nightly.

## Installation

1. Make sure the `julia` command works in a VSCode terminal.
2. Install `jetls-client` from the Extensions view by searching for
   `"JETLS Client"`.
3. Open any Julia file.

No separate JETLS installation is required. On first use, the extension
automatically installs a compatible JETLS server. It updates the server when an
extension update requires a newer version.

The extension stores JETLS separately from packages in your regular Julia
depot. Different Julia installations and Julia minor versions use separate
managed copies, and copies for a Julia you stopped using are removed
automatically after a while. You do not need to configure or maintain this
storage.

The first installation and each managed update require network access.
Once installed, the cached server can start while offline. The status bar shows
whether managed JETLS is being checked, installed, started, or has failed, and
installations show a progress notification from which they can be cancelled.

The extension launches only the exact JETLS version its release pins. When
that version cannot be installed or verified — for example, while offline —
startup fails with an error notification. The notification offers to retry
and to show the JETLS output, which records the full details; clicking the
failed status bar item opens the same output.

To recover from a broken managed installation, run
`JETLS Client: Reinstall Server` from the Command Palette.
The command asks for confirmation and installs a fresh copy, which
requires network access; superseded copies are cleaned up automatically.

## Launching configuration (advanced)

Most users do not need any configuration beyond the installation steps above.
When the defaults do not fit your setup, adjust how the server is launched
through the `jetls-client.executable` setting:

- To customize the managed server launch, use the object form with `path`
  omitted; the optional `threads` and `env` fields control the launch. For
  example, to select a Julia executable other than the default `julia`
  command, set `JULIA_APPS_JULIA_CMD`:

  ```jsonc
  {
    "jetls-client.executable": {
      "threads": "1", // the default is "auto"
      "env": {
        "JULIA_APPS_JULIA_CMD": "/absolute/path/to/julia"
      }
    }
  }
  ```

  The command must be the Julia executable itself (on Windows,
  `julia.exe` rather than a `.bat`/`.cmd` wrapper), since the managed
  installation launches it directly.

- To use a JETLS binary you manage yourself, specify its `path`.
  This bypasses managed installation and updates:

  ```jsonc
  {
    "jetls-client.executable": {
      "path": "/absolute/path/to/jetls"
    }
  }
  ```

- To develop JETLS from a local checkout, provide the full launch command
  as an array. This also bypasses managed installation:

  ```jsonc
  {
    "jetls-client.executable": [
      "julia",
      "--startup-file=no",
      "--history-file=no",
      "--project=/path/to/JETLS",
      "-m",
      "JETLS",
      "serve"
    ]
  }
  ```

### Communication channel

The extension automatically selects the most appropriate communication channel
based on your environment:

- **Local development**: `pipe` - Complete isolation from `stdin`/`stdout`,
  fastest for local communication
- **Remote SSH/WSL**: `pipe` - Works transparently across remote connections
- **Dev Containers**: `stdio` - Maximum compatibility for containerized
  environments

For most users, this automatic selection provides optimal performance and
reliability without requiring manual configuration.

You can override the automatic selection using `"jetls-client.communicationChannel": string`:

- `"auto"` (default): Automatic selection as described above
- `"pipe"`: Uses Unix domain socket/named pipe
- `"socket"`: Uses TCP socket (configure port with `"jetls-client.socketPort": number`,
  default `0` for auto-assign)
- `"stdio"`: Uses standard input/output

For detailed information about each communication channel and when to use them,
see the [Communication channels documentation](https://aviatesk.github.io/JETLS.jl/release/launching/#Communication-channels).

### Initialization options

Static options that are sent to JETLS during startup can be configured through
VSCode's `settings.json` file using the `"jetls-client.initializationOptions"`
section.
These settings require a server restart to take effect.

For detailed initialization options and examples, see the
[Initialization options documentation](https://aviatesk.github.io/JETLS.jl/release/launching/#init-options).

### Example initialization options

```jsonc
{
  "jetls-client.initializationOptions": {
    "analysis_overrides": [
      {
        "path": "test/fixtures/**",
        "full_analysis": false
      }
    ]
  }
}
```

## Configuring JETLS

JETLS behavior (diagnostics, formatting, etc.) can be configured through VSCode's
`settings.json` file using the `jetls-client.settings` section.

For detailed configuration options and examples, see the
[Configuration documentation](https://aviatesk.github.io/JETLS.jl/release/configuration/).

### Example configuration

> `.vscode/settings.json`

```jsonc
{
  "jetls-client.settings": {
    "full_analysis": {
      "debounce": 2.0
    },
    // Use JuliaFormatter instead of Runic
    "formatter": "JuliaFormatter",
    "diagnostic": {
      "patterns": [
        // Suppress toplevel/inference warnings in test folder
        {
          "pattern": "(toplevel|inference)/.*",
          "match_by": "code",
          "match_type": "regex",
          "severity": "off",
          "path": "test/**/*.jl"
        }
      ]
    },
    "testrunner": {
      "executable": "/path/to/custom/testrunner"
    }
  }
}
```

## License

MIT License. See [LICENSE.md](./LICENSE.md) for details.
