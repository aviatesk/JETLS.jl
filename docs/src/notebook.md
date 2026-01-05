# [Notebook support](@id notebook)

!!! warning "Experimental"
    Notebook support is experimental. The LSP specification for notebooks is
    still evolving, and `jetls-client` VS Code extension uses an unreleased
    version of [`vscode-languageclient`](https://www.npmjs.com/package/vscode-languageclient)
    to fully enable this feature.

JETLS provides language features for Julia code cells in notebooks. The LSP
notebook protocol is designed to be generic and can handle various notebook
formats, but JETLS currently focuses on Jupyter notebooks given the current
state of client implementations
(see the [Client support](@ref notebook/client-support) section below).

## Demo

```@raw html
<center>
<iframe class="display-light-only" style="width:100%;height:min(500px,70vh);aspect-ratio:16/9" src="https://github.com/user-attachments/assets/b5bb5201-d735-4a37-b430-932b519254ee" frameborder="0" allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>
<iframe class="display-dark-only" style="width:100%;height:min(500px,70vh);aspect-ratio:16/9" src="https://github.com/user-attachments/assets/f7476257-7a53-44a1-8c8c-1ad57e136a63" frameborder="0" allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>
</center>
```

As shown in this demo, all code cells are analyzed together as a single source,
as if the notebook were a single Julia script. The language server is aware of
all cells, so features like go-to-definition, completions, and diagnostics work
across cells just as they would in a regular Julia script.

## [Client support](@id notebook/client-support)

As of December 2025, notebook LSP is only supported by VS Code and VS Code-based
editors (such as [Cursor](https://cursor.com/), [Eclipse Theia](https://theia-ide.org/),
or [VS Codium](https://vscodium.com/)).

These clients currently only support Jupyter notebooks (`.ipynb` files).

Other editors like Neovim, Emacs, or Zed do not currently support the notebook
LSP protocol, so this feature is not available in those environments.

## [Usage](@id notebook/usage)

1. Open a `.ipynb` file in VS Code
2. Select "Julia" as the notebook kernel/language

The notebook environment is detected automatically, just like for regular Julia
scripts. If a `Project.toml` exists in the current or a parent directory, it
will be used as the project environment.
