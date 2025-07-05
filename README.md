# JETLS

[![](https://github.com/aviatesk/JETLS.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/aviatesk/JETLS.jl/actions/workflows/ci.yml)
[![](https://codecov.io/gh/aviatesk/JETLS.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/aviatesk/JETLS.jl)

The goal of this project is to develop a new language server for
[Julia](https://julialang.org/), currently called "JETLS".
This language server aims to enhance developer productivity by providing
advanced static analysis and seamless integration with the Julia runtime.
By leveraging tooling technologies like
[JET.jl](https://github.com/aviatesk/JET.jl),
[JuliaSyntax.jl](https://github.com/JuliaLang/JuliaSyntax.jl) and
[JuliaLowering.jl](https://github.com/c42f/JuliaLowering.jl),
JETLS aims to offer enhanced language features such as type-sensitive
diagnostics, macro-aware go-to definition and such.

This repository manages JETLS.jl, a Julia package that implements a language
server, and jetls-client, a sample VSCode extension that serves as a language
client for testing JETLS. For information on how to use JETLS with other
frontends, please refer to the [Other editors](#other-editors) section.

## Requirements

- VSCode v1.93.0 or higher
- npm v11.0.0 or higher
- Julia [`v"1.12.0-beta2"`](https://julialang.org/downloads/#upcoming_release)
  or higher

## Steps

- Run `julia --project=. -e 'using Pkg; Pkg.instantiate()'` in this folder to
  install all necessary Julia packages.
- Run `npm install` in this folder to install all necessary node modules for
  the client.
- Open this folder in VSCode.
- Press <kbd>Ctrl+Shift+B</kbd> to start compiling the client and server in
  [watch mode](https://code.visualstudio.com/docs/editor/tasks#:~:text=The%20first%20entry%20executes,the%20HelloWorld.js%20file.).
- Switch to the Run and Debug View in the Sidebar (<kbd>Ctrl+Shift+D</kbd>).
- Select `Launch Client` from the drop-down menu (if it is not already selected).
- Press `▷` to run the launch configuration (<kbd>F5</kbd>).
- In the [Extension Development Host](https://code.visualstudio.com/api/get-started/your-first-extension#:~:text=Then%2C%20inside%20the%20editor%2C%20press%20F5.%20This%20will%20compile%20and%20run%20the%20extension%20in%20a%20new%20Extension%20Development%20Host%20window.)
  instance of VSCode, open a Julia file.

## Roadmap

This is a summary of currently implemented features and features that will
likely be implemented in the near future, for those who want to test this server.
Please note that not only the progress of the list, but also the structure of
the list itself is subject to change.

- Full-Analysis
  - [x] Document synchronization
  - [ ] JuliaLowering integration
  - [ ] Incremental analysis
  - [ ] Recursive analysis for dependencies
  - [ ] Cross-server-process cache system
- Diagnostics
  - [x] Report undefined bindings
  - [x] Report unused bindings
  - [ ] Report potential `MethodError`
- Completion
  - [x] Global symbol completion
  - [x] Local binding completion
  - [x] LaTeX/Emoji completion
  - [ ] Method signature completion
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
- [ ] Formatting

Detailed development notes and progress for this project are collected at https://publish.obsidian.md/jetls,
so those interested might want to take a look.

## Development Notes

- [DEVELOPMENT.md](./DEVELOPMENT.md): Developer notes
- [AGENTS.md](./AGENTS.md): Specific coding rules (recommended reading for human developers as well)

## Other Editors

### Emacs
Minimal Emacs (eglot client) setup:
```lisp
(add-to-list 'eglot-server-programs
              '(((julia-mode :language-id "julia")
                (julia-ts-mode :language-id "julia"))
                "julia"
                "--startup-file=no"
                "--project=/path/to/JETLS.jl"
                "/path/to/JETLS.jl/runserver.jl"))
```
### Neovim

Minimal Neovim setup (requires Neovim v0.11):
```lua
vim.lsp.config("jetls", {
    cmd = {
        "julia",
        "--startup-file=no",
        "--project=/path/to/JETLS.jl",
        "/path/to/JETLS.jl/runserver.jl",
    },
    filetypes = {"julia"},
})
vim.lsp.enable("jetls")
```

### Zed
[Zed](https://zed.dev/) extension for Julia/JETLS is available:
See [aviatesk/zed-julia#avi/JETLS](https://github.com/aviatesk/zed-julia/tree/avi/JETLS).

### Helix

Minimal [Helix](https://helix-editor.com/) setup:

> `languages.toml`
```toml
[[language]]
name = "julia"
language-servers = [ "jetls" ]

[language-server]
jetls = { command = "julia", args = ["--startup-file=no", "--project=/path/to/JETLS.jl", "/path/to/JETLS.jl/runserver.jl"] }
```
