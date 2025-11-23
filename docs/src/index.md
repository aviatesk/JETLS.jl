# JETLS.jl documentation

[![](https://img.shields.io/badge/docs-user_guide-9558B2?logo=julia)](https://aviatesk.github.io/JETLS.jl/dev/)
[![](https://img.shields.io/badge/docs-dev_notes-7C3AED?logo=obsidian)](https://publish.obsidian.md/jetls)
[![](https://github.com/aviatesk/JETLS.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/aviatesk/JETLS.jl/actions/workflows/ci.yml)
[![](https://codecov.io/gh/aviatesk/JETLS.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/aviatesk/JETLS.jl)

The goal of this project is to develop a new language server for
[Julia](https://julialang.org/), currently called "JETLS".
JETLS aims to enhance developer productivity by providing advanced static
analysis and seamless integration with the Julia runtime.
By leveraging tooling technologies like
[JET.jl](https://github.com/aviatesk/JET.jl),
[JuliaSyntax.jl](https://github.com/JuliaLang/JuliaSyntax.jl) and
[JuliaLowering.jl](https://github.com/c42f/JuliaLowering.jl),
JETLS aims to offer enhanced language features such as type-sensitive
diagnostic, macro-aware go-to definition and such.

## Getting started

The easiest way to use JETLS is through
[`jetls-client`](https://marketplace.visualstudio.com/items?itemName=aviatesk.jetls-client),
a [VSCode](https://code.visualstudio.com/) client extension for JETLS.
This section explains how to use JETLS as the IDE backend via `jetls-client`.

For those who want to use JETLS with other editors, please refer to the [Other editors](@ref) section.

### Requirements

- [VSCode](https://code.visualstudio.com/) v1.96.0 or higher
- [Julia `v"1.12"`](https://julialang.org/downloads) or higher

### Steps

1. Install the `jetls` [executable app](https://pkgdocs.julialang.org/dev/apps/),
   which is the main entry point for running JETLS:
   ```bash
   julia -e 'using Pkg; Pkg.Apps.add("https://github.com/aviatesk/JETLS.jl")'
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

!!! info "Updating JETLS"
    To update JETLS to the latest version:
    ```bash
    julia -e 'using Pkg; Pkg.Apps.update("JETLS")'
    ```
    JETLS has not been officially released yet, so there is no versioning policy
    at this time. In the future, you will be able to install specific versions.

### Advanced: Customizing the executable

Most users do not need any further setups.
If needed, you can configure `jetls-client.executable` to customize how JETLS is launched:

- Adjust Julia thread count:
  ```json
  {
    "jetls-client.executable": {
      "path": "jetls",
      "threads": "4"  // default: "auto"
    }
  }
  ```

- Use a local JETLS checkout (for JETLS development):
  ```json
  {
    "jetls-client.executable": [
      "/path/to/julia/executable",
      "--startup-file=no",
      "--history-file=no",
      "--threads=auto",
      "--project=/path/to/JETLS",
      "-m",
      "JETLS"
    ]
  }
  ```

See [Communication channel configuration for VSCode](@ref communication/vscode) for advanced
client-server communication settings.

To configure JETLS behavior (diagnostics, formatting, etc.), use `jetls-client.settings`.
See [Configuration](@ref config/lsp-config/vscode) for more details.

## Other editors

For editors other than VSCode, first install the `jetls`
[executable app](https://pkgdocs.julialang.org/dev/apps/),
the main entry point for running JETLS:

```bash
julia -e 'using Pkg; Pkg.Apps.add("https://github.com/aviatesk/JETLS.jl")'
```

Make sure `~/.julia/bin` is available on the `PATH` environment so the `jetls`
executable (`jetls.exe` on Windows) is accessible.

!!! info "Updating JETLS"
    To update JETLS to the latest version:
    ```bash
    julia -e 'using Pkg; Pkg.Apps.update("JETLS")'
    ```
    JETLS has not been officially released yet, so there is no versioning policy
    at this time. In the future, you will be able to install specific versions.

Then, configure your editor's language client to use the `jetls` executable.

!!! warning
    These setups are basically very minimal and do not necessarily properly
    utilize the [Communication channels](@ref) that we recommend (i.e. `pipe-connect`,
    `pipe-listen`, or `socket`). Many of these setups simply use `stdio` as the
    communication channel, but as noted in the documentation, there are potential
    risks of breaking LSP connections due to writes to `stdout` that may occur
    when loading dependency packages.

### Emacs

Minimal [Emacs](https://www.gnu.org/software/emacs/)
([eglot](https://github.com/joaotavora/eglot) client) setup:

```lisp
(add-to-list 'eglot-server-programs
              '(((julia-mode :language-id "julia")
                (julia-ts-mode :language-id "julia"))
                "jetls"
                "--threads=auto"
                "--"
                "--socket"
                :autoport))
```

### Neovim

Minimal [Neovim](https://neovim.io/) setup (requires Neovim v0.11):

```lua
vim.lsp.config("jetls", {
    cmd = {
        "jetls",
        "--threads=auto",
        "--",
    },
    filetypes = {"julia"},
})
vim.lsp.enable("jetls")
```

### Zed

[Zed](https://zed.dev/) extension for Julia/JETLS is available:
See [`aviatesk/zed-julia#avi/JETLS`](https://github.com/aviatesk/zed-julia/tree/avi/JETLS)
for installation steps.

### Helix

Minimal [Helix](https://helix-editor.com/) setup:

> `languages.toml`
```toml
[[language]]
name = "julia"
language-servers = [ "jetls" ]

[language-server]
jetls = { command = "jetls", args = ["--threads=auto", "--"] }
```

## Quick links

```@contents
```
