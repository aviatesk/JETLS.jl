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
diagnostics, macro-aware go-to definition and such.

## Getting started

### VSCode

#### Requirements

- [VSCode](https://code.visualstudio.com/) v1.96.0 or higher
- Julia [`v"1.12.0"`](https://julialang.org/downloads/#current_stable_release)
  or higher

#### Steps

!!! info
    Currently, the `jetls-client` VSCode extension is not bundled with JETLS.jl
    as a Julia package, requiring you to explicitly specify the path to your
    JETLS.jl installation via the `jetls-client.jetlsDirectory` configuration
    and ensure the environment is properly initialized with `Pkg.instantiate()`.
    Since JETLS is currently distributed as source code, updates must be
    performed manually using `git pull`, followed by `Pkg.update()` and
    `Pkg.instantiate()` to refresh dependencies.

1. Clone and initialize this repository:
   ```bash
   git clone https://github.com/aviatesk/JETLS.jl.git
   cd JETLS.jl
   julia --project=. -e 'using Pkg; Pkg.instantiate()'
   ```
2. Install the JETLS Client VSCode extension ([`jetls-client`](https://marketplace.visualstudio.com/items?itemName=aviatesk.jetls-client)):
   - Open VSCode
   - Go to Extensions (Invoke the `View: Show Extensions` command)
   - Search for `"JETLS Client"`
   - Click `Install`
3. Configure the extension:
   - Open VSCode settings
   - Set `jetls-client.jetlsDirectory` to the path of the cloned JETLS.jl
     repository
   - (Optional) Set `jetls-client.juliaExecutablePath` to your Julia executable
     path (default: `julia`)
4. Open any Julia file

### Other editors

!!! info
    These setups use generic language clients, requiring you to explicitly
    specify the path to your JETLS.jl installation and ensure the environment
    is properly initialized with `Pkg.instantiate()`. Since JETLS is currently
    distributed as source code, updates must be performed manually using
    `git pull`, followed by `Pkg.update()` and `Pkg.instantiate()` to refresh
    dependencies.

!!! warning
    These setups are basically very minimal and do not necessarily properly
    utilize the [Communication channels](@ref) that we recommends (i.e. `pipe` or `socket`).
    Many of these setups simply use `stdio` as the communication channel, but
    as noted in the documentation, there are potential risks of breaking LSP
    connections due to writes to `stdout` that may occur when loading dependency
    packages.

#### Emacs

Minimal [Emacs](https://www.gnu.org/software/emacs/)
([eglot](https://github.com/joaotavora/eglot) client) setup:

```lisp
(add-to-list 'eglot-server-programs
              '(((julia-mode :language-id "julia")
                (julia-ts-mode :language-id "julia"))
                "julia"
                "--startup-file=no"
                "--history-file=no"
                "--project=/path/to/JETLS.jl"
                "--threads=auto"
                "/path/to/JETLS.jl/runserver.jl"
                "--socket"
                :autoport))
```

#### Neovim

Minimal [Neovim](https://neovim.io/) setup (requires Neovim v0.11):

```lua
vim.lsp.config("jetls", {
    cmd = {
        "julia",
        "--startup-file=no",
        "--history-file=no",
        "--project=/path/to/JETLS.jl",
        "--threads=auto",
        "/path/to/JETLS.jl/runserver.jl",
    },
    filetypes = {"julia"},
})
vim.lsp.enable("jetls")
```

#### Zed

[Zed](https://zed.dev/) extension for Julia/JETLS is available:
See [`aviatesk/zed-julia#avi/JETLS`](https://github.com/aviatesk/zed-julia/tree/avi/JETLS)
for installation steps.

#### Helix

Minimal [Helix](https://helix-editor.com/) setup:

> `languages.toml`
```toml
[[language]]
name = "julia"
language-servers = [ "jetls" ]

[language-server]
jetls = { command = "julia", args = ["--startup-file=no", "--history-file=no", "--project=/path/to/JETLS.jl", "--threads=auto", "/path/to/JETLS.jl/runserver.jl"] }
```

## Quick links

```@contents
```
