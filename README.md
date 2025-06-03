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
which has been organized to be easily recognized by AI agents (Claude models in particular).

### AI-Assisted Development
When working with AI agents for development, consider the following tips:
- AI agents generally produce highly random code without test code to guide
  them, yet they often struggle with writing quality test code themselves.
  Thus the recommended approach is to prepare solid test code yourself first,
  then ask the agent to implement the functionality based on these tests.
- AI agents will run the entire JETLS test suite using `Pkg.test()` if not
  specified otherwise, but as mentioned above, for best results, it's better to
  include which test code/files to run in your prompt.
- You can have the `./julia` script in the root directory of this repository to
  specify which Julia binary should be used by agents. If the script doesn't
  exist, the agent will default to using the system's `julia` command.
  For example, you can specify a local Julia build by creating a `./julia`
  script like this:
  > ./julia
  ```bash
  #!/usr/bin/env bash
  exec /path/to/julia/usr/bin/julia "$@"
  ```
  The `./julia` script is gitignored, so it won't be checked into the git tree.

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

### Dynamic Registration

This language server supports
[dynamic registration](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#client_registerCapability)
of LSP features.

With dynamic registration, for example, the server can switch the formatting
engine when users change their preferred formatter, or disable specific LSP
features upon configuration change, without restarting the server process
(although neither of these features has been implemented yet).

Dynamic registration is also convenient for language server development.
When enabling LSP features, the server needs to send various capabilities and
options to the client during initialization.
With dynamic registration, we can rewrite these activation options and re-enable
LSP features dynamically, i.e. without restarting the server process.

For example, you can dynamically add `,` as a `triggerCharacter` for
"completion" as follows. First, [launch `jetls-client` ](#steps) in VSCode[^vscode],
then add the following diff to unregister the already enabled completion feature.
Make a small edit to the file the language server is currently analyzing to send
some request from the client to the server. This will allow Revise to apply this
diff to the server process via the dev mode callback (see [runserver.jl](./runserver.jl)),
which should disable the completion feature:
```diff
diff --git a/src/completions.jl b/src/completions.jl
index 29d0db5..728da8f 100644
--- a/src/completions.jl
+++ b/src/completions.jl
@@ -21,6 +21,11 @@ completion_options() = CompletionOptions(;
 const COMPLETION_REGISTRATION_ID = "jetls-completion"
 const COMPLETION_REGISTRATION_METHOD = "textDocument/completion"

+let unreg = Unregistration(COMPLETION_REGISTRATION_ID, COMPLETION_REGISTRATION_METHOD)
+    unregister(currently_running, unreg)
+end
+
 function completion_registration()
     (; triggerCharacters, resolveProvider, completionItem) = completion_options()
     documentSelector = DocumentFilter[
```

> [!tip]
> You can add the diff above anywhere Revise can track and apply changes, i.e.
> any top-level scope in the `JETLS` module namespace or any subroutine
> of `_handle_message` that is reachable upon the request handling.

> [!warning]
> Note that `currently_running::Server` is a global variable that is only
> defined in `JETLS_DEV_MODE`. The use of this global variable should be limited
> to such development purposes and should not be included in normal routines.

[^vscode]: Of course, the hack explained here is only possible with clients that
  support dynamic registration. VSCode is currently one of the frontends that
  best supports dynamic registration.

After that, delete that diff and add the following diff:
```diff
diff --git a/src/completions.jl b/src/completions.jl
index 29d0db5..7609a6a 100644
--- a/src/completions.jl
+++ b/src/completions.jl
@@ -9,6 +9,7 @@ const COMPLETION_TRIGGER_CHARACTERS = [
     "@",  # macro completion
     "\\", # LaTeX completion
     ":",  # emoji completion
+    ",",  # new trigger character
     NUMERIC_CHARACTERS..., # allow these characters to be recognized by `CompletionContext.triggerCharacter`
 ]

@@ -36,6 +37,8 @@ function completion_registration()
             completionItem))
 end

+register(currently_running, completion_registration())
+
 # completion utils
 # ================
```

This should re-enable completion, and now completion will also be triggered when
you type `,`.

For these reasons, when adding new LSP features, check whether the feature
supports dynamic/static registration, and if it does, actively opt-in to use it.
That is, register it via the `client/registerCapability` request in response to
notifications sent from the client, most likely `InitializedNotification`.
The `JETLS.register` utility is especially useful for this purpose.

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
