# JETLS.jl

[![](https://github.com/aviatesk/JETLS.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/aviatesk/JETLS.jl/actions/workflows/ci.yml)
[![](https://codecov.io/gh/aviatesk/JETLS.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/aviatesk/JETLS.jl)

The goal of this project is to develop a new language server for
[Julia](https://julialang.org/), currently called "JETLS.jl".
This language server aims to enhance developer productivity by providing
advanced static analysis and seamless integration with the Julia runtime.
By leveraging tooling technologies like
[JET.jl](https://github.com/aviatesk/JET.jl),
[JuliaSyntax.jl](https://github.com/JuliaLang/JuliaSyntax.jl) and
[JuliaLowering.jl](https://github.com/c42f/JuliaLowering.jl).
JETLS aims to offer enhanced language features such as type-sensitive
diagnostics, macro-aware go-to definition and such.

This repository manages JETLS.jl, a Julia package that implements a language
server, and jetls-client, a sample VSCode extension that serves as a language
client for testing JETLS.jl. For information on how to use JETLS.jl with other
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

## Development Note

### Coding Guidelines
This section contains meta-documentation related to development.
For more detailed coding guidelines, please refer to [CLAUDE.md](./CLAUDE.md),
which has been organized to be easily shared with AI agents.

### `[sources]` Dependencies

In JETLS, since we need to use packages that aren’t yet registered
(e.g., [JuliaLowering.jl](https://github.com/c42f/JuliaLowering.jl)) or
specific branches of [JET.jl](https://github.com/c42f/JuliaLowering.jl) and
[JuliaSyntax.jl](https://github.com/JuliaLang/JuliaSyntax.jl),
the [Project.toml](./Project.toml) includes [`[sources]` section](https://pkgdocs.julialang.org/v1/toml-files/#The-[sources]-section).
The `[sources]` section allows simply running `Pkg.instantiate()` to install all
the required versions of these packages on any environment, including the CI
setup especially.

On the other hand, it can sometimes be convenient to `Pkg.develop` some of the
packages listed in the `[sources]` section and edit their source code while
developing JETLS. In particular, to have Revise immediately pick up changes made
to those packages, we may need to keep them in locally editable directories.
However, we cannot run `Pkg.develop` directly on packages listed in the
`[sources]` section, e.g.:
```julia-repl
julia> Pkg.develop("JET")
ERROR: `path` and `url` are conflicting specifications
...
```
To work around this, you can temporarily comment out the `[sources]` section and
run `Pkg.develop("JET")`.
This lets you use any local JET implementation. After running `Pkg.develop("JET")`,
you can restore the `[sources]` section, and perform any most of `Pkg`
operations without any issues onward.
The same applies to the other packages listed in `[sources]`.

### `JETLS_DEV_MODE`

JETLS has a development mode that can be enabled through the `JETLS_DEV_MODE`
[preference](https://github.com/JuliaPackaging/Preferences.jl).
When this mode is enabled, the language server enables several features to aid
in development:
- Automatic loading of Revise when starting the server, allowing changes to be
  applied without restarting
- `try`/`catch` block is added for the top-level handler of non-lifecycle-related
  messages, allowing the server to continue running even if an error occurs in
  each message handler, showing error messages and stack traces in the output
  panel

You can control this setting through Preferences.jl's mechanism:
```julia-repl
julia> using Preferences

julia> Preferences.set_preferences!("JETLS", "JETLS_DEV_MODE" => false; force=true) # disable the dev mode
```

`JETLS_DEV_MODE` is enabled by default when running the server at this moment of
prototyping, but also note that it is enabled when running the test suite.

## Other Editors

- Minimal Emacs (eglot client) setup:
  ```lisp
  (add-to-list 'eglot-server-programs
               '(((julia-mode :language-id "julia")
                  (julia-ts-mode :language-id "julia"))
                 "julia"
                 "--startup-file=no"
                 "--project=/path/to/JETLS.jl"
                 "/path/to/JETLS.jl/runserver.jl"))
  ```

- [Zed](https://zed.dev/) extension for Julia/JETLS is available:
  See [aviatesk/zed-julia#avi/JETLS](https://github.com/aviatesk/zed-julia/tree/avi/JETLS)
