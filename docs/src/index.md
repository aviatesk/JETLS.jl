# JETLS.jl documentation

The goal of this project is to develop a new language server for
[Julia](https://julialang.org/), currently called "JETLS".
JETLS aims to enhance developer productivity by providing advanced static
analysis and seamless integration with the Julia runtime.
By leveraging tooling technologies like
[JET.jl](https://github.com/aviatesk/JET.jl),
[JuliaSyntax.jl](https://github.com/JuliaLang/julia/tree/master/JuliaSyntax) and
[JuliaLowering.jl](https://github.com/JuliaLang/julia/tree/master/JuliaLowering),
JETLS aims to offer enhanced language features such as type-sensitive
diagnostic, macro-aware go-to definition and such.

!!! warning "Experimental"
    JETLS is under active development.
    Not production-ready; APIs and behavior may change.
    Stability and performance are limited. Expect bugs and rough edges.

## Server installation

Editor clients for JETLS generally do not bundle the JETLS server itself.
You need to install the `jetls` executable separately before using any editor integration.

### Prerequisites

JETLS requires [Julia `v"1.12"`](https://julialang.org/downloads) or higher (1.12.2+ recommended).

### Installing the `jetls` executable

All editor integrations require the [`jetls` executable app](https://pkgdocs.julialang.org/dev/apps/),
which is the main entry point for running JETLS.

Install it with:
```bash
julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="release")'
```

This will install the `jetls` executable to `~/.julia/bin/`.
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
is a [VSCode](https://code.visualstudio.com/) client extension for JETLS.

Install the `jetls-client` extension from the VSCode Extensions marketplace
(search for `"JETLS Client"` from the extensions view), then open any Julia file.
The extension will automatically use the `jetls` executable from your `PATH`.

For advanced launching configurations and JETLS behavior settings, see the
[jetls-client README](https://github.com/aviatesk/JETLS.jl/blob/master/jetls-client/README.md#advanced-launching-configuration).

!!! note
    Currently, JETLS.jl is not integrated with the
    [`julia-vscode` extension](https://www.julia-vscode.org/).
    To use JETLS from VSCode, install the `jetls-client` extension.
    While we generally recommend disabling `julia-vscode` when using `jetls-client`,
    this is not required; you can use both `julia-vscode` and `jetls-client`
    in the same VSCode session.
    However, since the LSP features provided by JETLS.jl differ in both type and quality
    from those provided by `julia-vscode`'s language server backend
    ([LanguageServer.jl](https://github.com/julia-vscode/LanguageServer.jl)),
    you may encounter confusing situations where, for example, completion candidates
    are provided from different backends.

### Emacs

Minimal [Emacs](https://www.gnu.org/software/emacs/)
([eglot](https://github.com/joaotavora/eglot) client) setup:

```lisp
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '(((julia-mode :language-id "julia")
                  (julia-ts-mode :language-id "julia"))
                 "jetls"
                 "serve"
                 "--threads=auto"
                 "--"
                 "--socket"
                 :autoport)))
```

### Vim
Minimal [Vim](https://www.vim.org) setup using the
[Vim9 LSP plugin](https://github.com/yegappan/lsp)

```vim
call LspAddServer([#{name: 'JETLS.jl',
                 \   filetype: 'julia',
                 \   path: 'jetls',
                 \   args: [
                 \       'serve',
                 \       '--threads=auto',
                 \       '--'
                 \   ]
                 \ }])
```

### Neovim

Minimal [Neovim](https://neovim.io/) setup (requires Neovim v0.11):

```lua
vim.lsp.config("jetls", {
    cmd = {
        "jetls",
        "serve",
        "--threads=auto",
        "--",
    },
    filetypes = { "julia" },
    root_markers = { "Project.toml" }
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
      "command": ["jetls", "serve", "--threads=auto", "--", "--socket=${port}"],
      "selector": "source.julia",
      "tcp_port": 0
    }
  }
}
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
jetls = { command = "jetls", args = ["serve", "--threads=auto", "--"] }
```

### Advanced: using local JETLS checkout

Advanced users can run JETLS directly from a local checkout by replacing
the `jetls` executable with `julia -m JETLS`:
```bash
julia --startup-file=no --project=/path/to/JETLS -m JETLS serve
```

!!! warning
    When using a local checkout other than the `release` branch (e.g. `master`),
    JETLS dependencies may conflict with the dependencies of the code being
    analyzed. The `release` branch avoids this by vendoring dependencies with
    rewritten UUIDs.

## Quick links

```@contents
Pages = Main.quick_links_pages
```
