# JETLS

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

This repository manages JETLS.jl, a Julia package that implements a language
server, and [`jetls-client`](https://marketplace.visualstudio.com/items?itemName=aviatesk.jetls-client),
a sample VSCode extension that serves as a language client for testing JETLS.

## Documentation

For end-user documentation including installation instructions, configuration
options, and feature guides, please visit the **[user guide documentation](https://aviatesk.github.io/JETLS.jl/dev/)**.

This README focuses on development-related information such as the project
roadmap, implementation status, and developer resources.

## Roadmap

This is a summary of currently implemented features and features that will
likely be implemented in the near future, for those who want to test this server.
Please note that not only the progress of the list, but also the structure of
the list itself is subject to change.

- Analysis
  - [x] Document synchronization
  - [ ] Incremental analysis
  - [ ] JuliaLowering integration
  - [ ] Recursive analysis for dependencies
  - [ ] Cross-server-process cache system
- Diagnostic
  - [x] Syntax errors
  - [x] Lowering errors
  - [x] Undefined bindings
  - [x] Unused bindings
  - [ ] Potential `MethodError`
  - [x] Configuration support
- Completion
  - [x] Global symbol completion
  - [x] Local binding completion
  - [x] LaTeX/Emoji completion
  - [ ] Method signature completion
  - [ ] Property completion
- Signature Help
  - [x] Basic implementation
  - [x] Macro support
  - [ ] Argument type based suggestion
- Definition
  - [x] Method defintion
  - [ ] Global binding definition
  - [x] Local binding definition
  - [ ] Type-aware method definition
- Hover
  - [x] Method documentation
  - [x] Global binding documentation
  - [x] Local binding location
  - [ ] Type-aware method documentation
  - [ ] Type of local binding on hover
- Formatting
  - [x] [Runic](https://github.com/fredrikekre/Runic.jl) integration
  - [x] [JuliaFormatter](https://github.com/domluna/JuliaFormatter.jl) integration
  - [x] Make formatting backend configurable
- Document Highlight
  - [x] Local binding
  - [x] Global binding
  - [ ] Field name, dot-accessed bindings
- Rename
  - [x] Local binding
  - [ ] Global binding
  - [ ] Field name
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
- [ ] Notebook support
- Release
  - [x] Publish a standalone VSCode language client extension
  - [ ] Environment isolution
  - [ ] Bundle JETLS (as a Julia package)
  - [ ] Integration into [julia-vscode](https://github.com/julia-vscode/julia-vscode)

## Development notes

The following documents contain specific items that should be referenced when
developing JETLS:
- [DEVELOPMENT.md](./DEVELOPMENT.md): Developer notes
- [AGENTS.md](./AGENTS.md): Specific coding rules (recommended reading for human developers as well)

Meta-level discussions, research, and ideas related to the development of JETLS
are compiled as [Obsidian](https://obsidian.md/) notes at <https://publish.obsidian.md/jetls>.
