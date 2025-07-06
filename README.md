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
- TestRunner.jl integration
  - [x] Code lens for running individual `@testset`s
  - [x] Code actions for running individual `@testset`s
  - [x] Code actions for running individual `@test` cases
  - [x] Inline test result diagnostics
  - [x] Work done progress during test execution

Detailed development notes and progress for this project are collected at
<https://publish.obsidian.md/jetls>, so those interested might want to take a look.

## TestRunner Integration

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

#### Code Lens

When you open a Julia file containing `@testset` blocks, JETLS displays
interactive code lenses above each `@testset`:

- **`▶ Run "testset_name"`**: Run the testset for the first time
> ![TestRunner Code Lens](./assets/testrunner-code-lens-dark.png#gh-dark-mode-only)
> ![TestRunner Code Lens](./assets/testrunner-code-lens-light.png#gh-light-mode-only)

After running tests, the code lens is refreshed as follows:
- **`▶ Rerun "testset_name" [summary]`**: Re-run a testset that has previous
  results
- **`☰ Open logs`**: View the detailed test output in a new editor tab
- **`✓ Clear result`**: Remove the test results and inline diagnostics
> ![TestRunner Code Lens with Results](./assets/testrunner-code-lens-refreshed-dark.png#gh-dark-mode-only)
> ![TestRunner Code Lens with Results](./assets/testrunner-code-lens-refreshed-light.png#gh-light-mode-only)

#### Code Actions

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

#### Test Diagnostics

Failed tests are displayed as diagnostics (red squiggly lines) at the exact
lines where the failures occurred, making it easy to identify and fix issues:
> ![TestRunner Diagnostics](./assets/testrunner-diagnostics-dark.png#gh-dark-mode-only)
> ![TestRunner Diagnostics](./assets/testrunner-diagnostics-light.png#gh-light-mode-only)

#### Progress Notifications

For clients that support work done progress, JETLS shows progress notifications
while tests are running, keeping you informed about long-running test suites.

### Supported Patterns

The TestRunner integration supports:

1. **Named `@testset` blocks** (via code lens or code actions):
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

2. **Individual `@test` macros** (via code actions only):
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

## Development Note

- [DEVELOPMENT.md](./DEVELOPMENT.md): Developer notes
- [AGENTS.md](./AGENTS.md): Specific coding rules (recommended reading for human developers as well)
