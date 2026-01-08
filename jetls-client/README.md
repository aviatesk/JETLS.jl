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
- [Julia `v"1.12"`](https://julialang.org/downloads) or higher (1.12.2+ recommended)

## Installation

> [!warning]
> The `jetls-client` extension does not bundle JETLS.jl itself. You need to
> install the `jetls` executable separately before using the extension.

1. Install the [`jetls` executable app](https://pkgdocs.julialang.org/dev/apps/),
   which is the main entry point for running JETLS:
   ```bash
   julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="release")'
   ```
   This will install the `jetls` executable to `~/.julia/bin/`.
2. Make sure `~/.julia/bin` is available on the `PATH` environment so the `jetls` executable is accessible.
   You can verify the installation by running:
   ```bash
   jetls --help
   ```
   If this displays the help message, the installation was successful and `~/.julia/bin`
   is properly added to your `PATH`.
3. Install `jetls-client`:
   - Open VSCode
   - Go to Extensions (Invoke the `View: Show Extensions` command)
   - Search for `"JETLS Client"`
   - Click `Install`
4. Open any Julia file

The extension will automatically use the `jetls` executable from your `PATH`.

> [!note]
> To update JETLS to the latest version, re-run the installation command:
>
> ```bash
> julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="release")'
> ```
>
> To pin a specific version instead, use the release tag `rev="YYYY-MM-DD"`:
>
> ```bash
> julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2025-11-25")'
> ```

## Launching configuration (advanced)

Most users do not need any further configuration beyond the installation steps
above. The following settings are available for advanced use cases.

### Executable configuration

Configure the JETLS executable through the `jetls-client.executable` setting:

- **Object form** `{"path": string, "threads": string}`: Customize the executable path or thread
  setting (default: `{"path": "jetls", "threads": "auto"}`)
- **Array form** `string[]`: Use a local JETLS checkout for development, e.g,
  (`["julia", "--startup-file=no", "--history-file=no", "--project=/path/to/JETLS", "-m", "JETLS"]`)

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
    "n_analysis_workers": 2
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
