# JETLS

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
For information on how to use JETLS with other frontends, please refer to the
[Other editors](#other-editors) section.

## Getting started with VSCode

> [!IMPORTANT]
> Currently, the `jetls-client` VSCode extension is not bundled with JETLS.jl
> as a Julia package, requiring you to explicitly specify the path to your
> JETLS.jl installation via the `jetls-client.jetlsDirectory` configuration
> and ensure the environment is properly initialized with `Pkg.instantiate()`.
> Since JETLS is currently distributed as source code, updates must be
> performed manually using `git pull`, followed by `Pkg.update()` and
> `Pkg.instantiate()` to refresh dependencies.

### Requirements

- [VSCode](https://code.visualstudio.com/) v1.96.0 or higher
- Julia [`v"1.12.0"`](https://julialang.org/downloads/#current_stable_release)
  or higher

### Steps

1. Clone and initialize this repository:
   ```bash
   git clone https://github.com/aviatesk/JETLS.jl.git
   cd JETLS.jl
   julia --project=. -e 'using Pkg; Pkg.instantiate()'
   ```
2. Install the JETLS Client VSCode extension (`jetls-client`):
   - Open VSCode
   - Go to Extensions (Invoke the `View: Show Extensions` command)
   - Search for `"JETLS Client"`
   - Click `Install`
3. Configure the extension:
   - Open VSCode settings
   - Set `jetls-client.jetlsDirectory` to the path of the cloned JETLS.jl repository
   - (Optional) Set `jetls-client.juliaExecutablePath` to your Julia executable path (default: `julia`)
4. Open any Julia file

## Communication channels

JETLS supports multiple communication channels between the client and server.
Choose based on your environment and requirements:

### `auto` (Default for VSCode)
The `jetls-client` VSCode extension automatically selects the most appropriate
channel based on your environment:
- Local development: `pipe` for maximum safety
- Remote SSH/WSL: `pipe` (works well in these environments)
- Dev Containers: `stdio` for compatibility

### `pipe` (Unix domain socket / named pipe)
- Advantages: Complete isolation from `stdin`/`stdout`, preventing protocol
  corruption; fastest for local communication
- Best for: Local development, Remote SSH, WSL
- Limitations: Not suitable for cross-container communication

### `socket` (TCP)
- Advantages: Complete isolation from `stdin`/`stdout`, preventing protocol
  corruption; works across network boundaries; supports port forwarding
- Best for: Remote development with port forwarding
- Limitations: May require firewall configuration; potentially less secure
  than local alternatives

### `stdio`
- Advantages: Simplest setup; maximum compatibility; works everywhere
- Best for: Dev containers; environments where `pipe` doesn't work
- Limitations: Risk of protocol corruption if any code writes to
  `stdin`/`stdout`

> [!WARNING]
> When using `stdio` mode, any `println(stdout, ...)` in your code or dependency
> packages may corrupt the LSP protocol and break the connection. Prefer `pipe`
> or `socket` modes when possible.

### Command-line usage

When using JETLS from the command line or with other editors:

```bash
# Standard input/output (default, --stdio can be omitted)
julia runserver.jl --stdio

# Unix domain socket or Windows named pipe
julia runserver.jl --pipe=/tmp/jetls.sock

# TCP socket
julia runserver.jl --socket=7777
```

## Other editors

> [!IMPORTANT]
> These setups use generic language clients, requiring you to explicitly
> specify the path to your JETLS.jl installation and ensure the environment
> is properly initialized with `Pkg.instantiate()`. Since JETLS is currently
> distributed as source code, updates must be performed manually using
> `git pull`, followed by `Pkg.update()` and `Pkg.instantiate()` to refresh
> dependencies.

> [!WARNING]
> These setups are basically very minimal and do not necessarily properly
> utilize the communication channels described above. Many of these setups
> simply use `stdio` as the communication channel, but as noted above, there
> are potential risks of breaking LSP connections due to writes to `stdout`
> that may occur when loading dependency packages.

### Emacs
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

### Neovim
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

### Zed
[Zed](https://zed.dev/) extension for Julia/JETLS is available:
See [aviatesk/zed-julia#avi/JETLS](https://github.com/aviatesk/zed-julia/tree/avi/JETLS)
for installation steps.

### Helix
Minimal [Helix](https://helix-editor.com/) setup:

> `languages.toml`
```toml
[[language]]
name = "julia"
language-servers = [ "jetls" ]

[language-server]
jetls = { command = "julia", args = ["--startup-file=no", "--history-file=no", "--project=/path/to/JETLS.jl", "--threads=auto", "/path/to/JETLS.jl/runserver.jl"] }
```

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
- Diagnostics
  - [x] Syntax errors
  - [x] Lowering errors
  - [x] Undefined bindings
  - [x] Unused bindings
  - [ ] Potential `MethodError`
  - [ ] Configuration integration
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
- Document Highlight
  - [x] Highlight local binding
- Hover
  - [x] Method documentation
  - [x] Global binding documentation
  - [x] Local binding location
  - [ ] Type-aware method documentation
  - [ ] Type of local binding on hover
- Formatting
  - [x] [Runic](https://github.com/fredrikekre/Runic.jl) integration
  - [ ] [JuliaFormatter](https://github.com/domluna/JuliaFormatter.jl) integration
  - [ ] Make formatting backend configurable
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
  - [ ] Support LSP configurations
  - [ ] Documentation
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

Detailed development notes and progress for this project are collected at
<https://publish.obsidian.md/jetls>, so those interested might want to take a look.

## TestRunner integration

JETLS integrates with [TestRunner.jl](https://github.com/aviatesk/TestRunner.jl)
to provide an enhanced testing experience directly within your editor. This
feature allows you to run individual `@testset` blocks directly from your
development environment.

### Prerequisites

To use this feature, you need to install the `testrunner` executable:

```bash
julia -e 'using Pkg; Pkg.Apps.add(url="https://github.com/aviatesk/TestRunner.jl")'
```

Note that you need to manually make `~/.julia/bin` available on the `PATH`
environment for the `testrunner` executable to be accessible.
See <https://pkgdocs.julialang.org/dev/apps/> for the details.

### Features

#### Code lens

When you open a Julia file containing `@testset` blocks, JETLS displays
interactive code lenses above each `@testset`:

- `▶ Run "testset_name"`: Run the testset for the first time
> ![TestRunner Code Lens](./assets/testrunner-code-lens-dark.png#gh-dark-mode-only)
> ![TestRunner Code Lens](./assets/testrunner-code-lens-light.png#gh-light-mode-only)

After running tests, the code lens is refreshed as follows:
- `▶ Rerun "testset_name" [summary]`: Re-run a testset that has previous
  results
- `☰ Open logs`: View the detailed test output in a new editor tab
- `✓ Clear result`: Remove the test results and inline diagnostics
> ![TestRunner Code Lens with Results](./assets/testrunner-code-lens-refreshed-dark.png#gh-dark-mode-only)
> ![TestRunner Code Lens with Results](./assets/testrunner-code-lens-refreshed-light.png#gh-light-mode-only)

#### Code actions

You can trigger test runs via "code actions" when the code action range is
requested:
- Inside a `@testset` block: Run the entire testset
> ![TestRunner Code Actions](./assets/testrunner-code-actions-dark.png#gh-dark-mode-only)
> ![TestRunner Code Actions](./assets/testrunner-code-actions-light.png#gh-light-mode-only)

- On an individual `@test` macro: Run just that specific test case
> ![TestRunner Code Actions `@test` case](./assets/testrunner-code-actions-test-case-dark.png#gh-dark-mode-only)
> ![TestRunner Code Actions `@test` case](./assets/testrunner-code-actions-test-case-light.png#gh-light-mode-only)

Note that when running individual `@test` cases, the error results are displayed
as temporary diagnostics for 10 seconds. Click `☰ Open logs` button in the
pop up message to view detailed error messages that persist.

#### Test diagnostics

Failed tests are displayed as diagnostics (red squiggly lines) at the exact
lines where the failures occurred, making it easy to identify and fix issues:
> ![TestRunner Diagnostics](./assets/testrunner-diagnostics-dark.png#gh-dark-mode-only)
> ![TestRunner Diagnostics](./assets/testrunner-diagnostics-light.png#gh-light-mode-only)

#### Progress notifications

For clients that support work done progress, JETLS shows progress notifications
while tests are running, keeping you informed about long-running test suites.

### Supported patterns

The TestRunner integration supports:

1. Named `@testset` blocks (via code lens or code actions):
```julia
using Test

# supported: named `@testset`
@testset "foo" begin
    @test sin(0) == 0
    @test sin(Inf) == 0
    @test_throws ErrorException sin(Inf) == 0
    @test cos(π) == -1

    # supported: nested named `@testset`
    @testset "bar" begin
        @test sin(π) == 0
        @test sin(0) == 1
        @test cos(Inf) == -1
    end
end

# unsupported: `@testset` inside function definition
function test_func1()
    @testset "inside function" begin
        @test true
    end
end

# supported: this pattern is fine
function test_func2()
    @testset "inside function" begin
        @test true
    end
end
@testset "test_func2" test_func2()
```

2. Individual `@test` macros (via code actions only):
```julia
# Run individual tests directly
@test 1 + 1 == 2
@test sqrt(4) ≈ 2.0

# Also works inside testsets
@testset "math tests" begin
    @test sin(0) == 0  # Can run just this test
    @test cos(π) == -1  # Or just this one
end

# Multi-line `@test` expressions are just fine
@test begin
    x = complex_calculation()
    validate(x)
end

# Other Test.jl macros are supported too
@test_throws DomainErrors sin(Inf)
```

See the [README.md](https://github.com/aviatesk/TestRunner.jl) of TestRunner.jl
for more details.

### Troubleshooting

If you see an error about `testrunner` not being found:
1. Ensure you've installed TestRunner.jl as described above
2. Check that `testrunner` is in your system PATH by running `which testrunner`:
   otherwise you may need to add `~/.julia/bin` to `PATH`
3. Restart your editor to ensure it picks up the updated PATH

Test execution requires that your file is saved and matches the on-disk version.
If you see a message asking you to save the file first, make sure to save your
changes before running tests.

## Development note

- [DEVELOPMENT.md](./DEVELOPMENT.md): Developer notes
- [AGENTS.md](./AGENTS.md): Specific coding rules (recommended reading for human developers as well)
