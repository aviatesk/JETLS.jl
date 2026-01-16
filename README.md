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

## Documentation

For end-user documentation including installation instructions, configuration
options, and feature guides, please visit the **[user guide documentation](https://aviatesk.github.io/JETLS.jl/)**.

This README focuses on development-related information such as the project
roadmap, implementation status, and developer resources.

## Roadmap

This is a summary of currently implemented features and features that will
likely be implemented in the near future, for those who want to test this server.
Please note that not only the progress of the list, but also the structure of
the list itself is subject to change.

- Analysis
  - [x] Document synchronization
  - [/] Incremental analysis
  - [ ] JuliaLowering integration
  - [ ] Recursive analysis for dependencies
  - [ ] Cross-server-process cache system
- Diagnostic
  - [x] Syntax errors
  - [x] Lowering errors
  - [x] Macro expansion error
  - [x] Unused bindings
  - [x] Captured boxed variables
  - [x] Method overwrite
  - [x] Abstract struct field
  - [x] Undefined bindings
  - [x] Non-existent struct fields
  - [x] Out-of-bounds field access by index
  - [ ] Potential `MethodError`
  - [x] Configuration support
- Completion
  - [x] Global symbol completion
  - [x] Local binding completion
  - [x] LaTeX/Emoji completion
  - [x] Method signature completion
  - [/] Argument type based matched method filtering
  - [x] [Juno](https://junolab.org/)-like return type annotation for method completions
  - [x] Keyword argument name completion
  - [ ] Property completion
- Signature help
  - [x] Basic implementation
  - [x] Macro support
  - [/] Argument type based matched method filtering
- Definition
  - [x] Method defintion
  - [x] Global binding definition
  - [x] Local binding definition
  - [ ] Type-aware method definition
- Hover
  - [x] Method documentation
  - [x] Global binding documentation
  - [x] Local binding location
  - [ ] Type of local binding
  - [ ] Type-aware method documentation
- Inlay hint
  - [ ] Method parameter name
  - [ ] Type of binding
- Formatting
  - [x] [Runic](https://github.com/fredrikekre/Runic.jl) integration
  - [x] [JuliaFormatter](https://github.com/domluna/JuliaFormatter.jl) integration
  - [x] Make formatting backend configurable
- Document highlight
  - [x] Local binding
  - [x] Global binding
  - [ ] Field name / Dot-accessed bindings
- Find references / Rename
  - [x] Local binding
  - Global reference
    - [x] Minimum support
    - [ ] Cross-analysis-unit reference detection
    - [ ] Aliased reference support
  - [ ] Field name
  - [x] File rename support (Julia-side rename)
  - [ ] File rename support (external rename)
- [x] Document symbol
- [x] Workspace symbol
- TestRunner.jl integration
  - [x] Code lens for running individual `@testset`s
  - [x] Code actions for running individual `@testset`s
  - [x] Code actions for running individual `@test` cases
  - [x] Inline test result diagnostics
- Configuration system
  - [x] Type stable config object implementation
  - [x] Support LSP configurations
  - [x] Documentation
  - [ ] Schema support
- [x] Parallel/concurrent message handling
- [x] Work done progress support
- [x] Message cancellation support
- [x] Notebook support
- Release
  - [x] Publish a standalone VSCode language client extension
  - [x] Make installable as Pkg executable app
  - [x] Environment isolution
  - [ ] Automatic server installation/update for `jetls-client`
  - [ ] Integration into [julia-vscode](https://github.com/julia-vscode/julia-vscode)

## Development notes

The following documents contain specific items that should be referenced when
developing JETLS:

- [DEVELOPMENT.md](./DEVELOPMENT.md): Developer notes
- [AGENTS.md](./AGENTS.md): Specific coding rules (recommended reading for human developers as well)

Meta-level discussions, research, and ideas related to the development of JETLS
are compiled as [Obsidian](https://obsidian.md/) notes at <https://publish.obsidian.md/jetls>.

## License

MIT License. See [LICENSE.md](./LICENSE.md) for details.
