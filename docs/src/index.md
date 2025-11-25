# JETLS.jl documentation

[![](https://github.com/aviatesk/JETLS.jl/actions/workflows/Documentation.yml/badge.svg)](https://github.com/aviatesk/JETLS.jl/actions/workflows/Documentation.yml)

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

## Server installation

Editor clients for JETLS generally do not bundle the JETLS server itself.
You need to install the `jetls` executable separately before using any editor integration.

### Prerequisites

JETLS requires [Julia `v"1.12"`](https://julialang.org/downloads) or higher,
so ensure that the Julia version of the `julia` command you use is v1.12 or higher.

### Installing the `jetls` executable

All editor integrations require the [`jetls` executable app](https://pkgdocs.julialang.org/dev/apps/),
which is the main entry point for running JETLS.

Install it with:
```bash
julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="release")'
```

This will install the `jetls` executable (`jetls.exe` on Windows) to `~/.julia/bin/`.
Make sure `~/.julia/bin` is available on the `PATH` environment so the executable is accessible.

You can verify the installation by running:
```bash
jetls --help
```
If this displays the help message, the installation was successful and `~/.julia/bin`
is properly added to your `PATH`.

!!! info "Updating JETLS"
    To update JETLS to the latest version:
    ```bash
    julia -e 'using Pkg; Pkg.Apps.update("JETLS")'
    ```
    JETLS has not been officially released yet, so there is no versioning policy
    at this time. In the future, you will be able to install specific versions.

## Editor setup

After installing the `jetls` executable, set up your editor to use it.

### VSCode

[`jetls-client`](https://marketplace.visualstudio.com/items?itemName=aviatesk.jetls-client)
is a [VSCode](https://code.visualstudio.com/) client extension for JETLS.[^1]

[^1]: Requires [VSCode](https://code.visualstudio.com/) v1.96.0 or higher.

Install the `jetls-client` extension from the VSCode Extensions marketplace
(search for `"JETLS Client"` from the extensions view), then open any Julia file.
The extension will automatically use the `jetls` executable from your `PATH`.

For advanced launching configurations and JETLS behavior settings, see the
[jetls-client README](https://github.com/aviatesk/JETLS.jl/blob/master/jetls-client/README.md#advanced-launching-configuration).

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
for the detailed installation steps.

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
