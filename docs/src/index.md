# JETLS.jl documentation

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

This will install the `jetls` executable (`jetls.bat` on Windows) to `~/.julia/bin/`.
Make sure `~/.julia/bin` is available on the `PATH` environment so the executable is accessible.

You can verify the installation by running:
```bash
jetls --help
```
If this displays the help message, the installation was successful and `~/.julia/bin`
is properly added to your `PATH`.

!!! info "Updating JETLS"
    To update JETLS to the latest version, re-run the installation command:
    ```bash
    julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="release")'
    ```

    To pin a specific version instead, use the release tag `rev="YYYY-MM-DD"`:
    ```bash
    julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="2025-11-25")'
    ```

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
### Sublime

Minimal [Sublime](https://www.sublimetext.com/) setup using the
[Sublime-LSP plugin](https://github.com/sublimelsp/LSP) and modifying the
`LSP.sublime-settings` file:

```json
{
    "clients": {
        "jetls": {
            "enabled": true,
            "command": ["jetls", "--threads=auto", "--", "--socket=${port}"],
            "selector": "source.julia",
            "tcp_port": 0
        }
    }
}
```

### Vim
Minimal [Vim](https://www.vim.org) setup using the
[Vim9 LSP plugin](https://github.com/yegappan/lsp)

```vim
call LspAddServer([#{name: 'JETLS.jl',
                 \   filetype: 'julia',
                 \   path: 'jetls',
                 \   args: [
                 \       '--threads=auto',
                 \       '--'
                 \   ]
                 \ }])
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
