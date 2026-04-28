# JETLS

[![](https://img.shields.io/badge/docs-user_guide-9558B2?logo=julia)](https://aviatesk.github.io/JETLS.jl/)
[![](https://img.shields.io/badge/docs-dev_notes-7C3AED?logo=obsidian)](https://publish.obsidian.md/jetls)
[![](https://github.com/aviatesk/JETLS.jl/actions/workflows/JETLS.jl.yml/badge.svg)](https://github.com/aviatesk/JETLS.jl/actions/workflows/JETLS.jl.yml)
[![](https://codecov.io/gh/aviatesk/JETLS.jl/branch/master/graph/badge.svg?flag=JETLS.jl)](https://codecov.io/gh/aviatesk/JETLS.jl&flags[0]=JETLS.jl)

The goal of this project is to develop a new language server for
[Julia](https://julialang.org/), currently called "JETLS".
JETLS aims to enhance developer productivity by providing advanced static
analysis and seamless integration with the Julia runtime.
By leveraging tooling technologies like
[JET.jl](https://github.com/aviatesk/JET.jl),
[JuliaSyntax.jl](https://github.com/JuliaLang/julia/tree/master/JuliaSyntax) and
[JuliaLowering.jl](https://github.com/JuliaLang/julia/tree/master/JuliaLowering),
JETLS aims to offer enhanced language features such as type-sensitive
diagnostics, macro-aware go-to definition and such.

This repository manages JETLS.jl, a Julia package that implements a language
server, and [`jetls-client`](https://marketplace.visualstudio.com/items?itemName=aviatesk.jetls-client),
a sample VSCode extension that serves as a language client for testing JETLS.

> [!warning]
> **Experimental**: JETLS is under active development.
> Not production-ready; APIs and behavior may change.
> Stability and performance are limited. Expect bugs and rough edges.

> [!warning]
> JETLS requires Julia 1.12.2 or later.
> It does not support Julia 1.12.1 or earlier, nor Julia 1.13+/nightly.

## Documentation

For end-user documentation including installation instructions, configuration
options, and feature guides, please visit the **[user guide documentation](https://aviatesk.github.io/JETLS.jl/)**.

## Development notes

The following documents contain specific items that should be referenced when
developing JETLS:

- [DEVELOPMENT.md](./DEVELOPMENT.md): Developer notes
- [AGENTS.md](./AGENTS.md): Specific coding rules (recommended reading for human developers as well)

Meta-level discussions, research, and ideas related to the development of JETLS
are compiled as [Obsidian](https://obsidian.md/) notes at <https://publish.obsidian.md/jetls>.

## License

MIT License. See [LICENSE.md](./LICENSE.md) for details.
