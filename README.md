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
See [`aviatesk/zed-julia#avi/JETLS`](https://github.com/aviatesk/zed-julia/tree/avi/JETLS)
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
  - [x] [JuliaFormatter](https://github.com/domluna/JuliaFormatter.jl) integration
  - [x] Make formatting backend configurable
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

Detailed development notes and progress for this project are collected at
<https://publish.obsidian.md/jetls>, so those interested might want to take a look.

## Configuration

JETLS supports various configuration options.
This documentation uses TOML format to describe the configuration schema.

### Available configurations

#### `[full_analysis] debounce`

- Type: number (seconds)
- Default: `1.0`

Debounce time in seconds before triggering full analysis after a document
change. JETLS performs type-aware analysis using
[JET.jl](https://github.com/aviatesk/JET.jl) to detect potential errors.
Higher values reduce analysis frequency (saving CPU) but may feel less
responsive.

```toml
[full_analysis]
debounce = 2.0  # Wait 2 seconds after typing stops before analyzing
```

#### `formatter`

- Type: string or table
- Default: `"Runic"`

Configures the formatter backend for document and range formatting. Accepts
either a preset formatter name or a custom formatter configuration.

Preset options:
- `"Runic"` (default): Uses [Runic.jl](https://github.com/fredrikekre/Runic.jl)
- `"JuliaFormatter"`: Uses [JuliaFormatter.jl](https://github.com/domluna/JuliaFormatter.jl)

Examples:
```toml
# Use JuliaFormatter preset
formatter = "JuliaFormatter"

# Or use custom formatter (both fields optional)
[formatter.custom]
executable = "/path/to/custom-formatter"
executable_range = "/path/to/custom-range-formatter"
```

See [Formatting](#formatting) for detailed configuration instructions and setup
requirements.

#### `[testrunner] executable`

- Type: string (path)
- Default: `"testrunner"` (or `"testrunner.bat"` on Windows)

Path to the [TestRunner.jl](https://github.com/aviatesk/TestRunner.jl)
executable for running individual `@testset` blocks and `@test` cases. If not
specified, JETLS looks for `testrunner` in your `PATH` (typically
`~/.julia/bin/testrunner`).

```toml
[testrunner]
executable = "/custom/path/to/testrunner"
```

See [TestRunner integration](#testrunner-integration) for setup instructions.

### How to configure JETLS

#### Method 1: Project-specific configuration file

Create a `.JETLSConfig.toml` file in your project root.
This configuration method works client-agnostically, thus allows projects to
commit configuration to VCS without writing JETLS configurations in various
formats that each client can understand.

> Example `.JETLSConfig.toml`:
```toml
[full_analysis]
debounce = 2.0

[testrunner]
executable = "/custom/path/to/testrunner"

# Use JuliaFormatter instead of Runic
formatter = "JuliaFormatter"
```

#### Method 2: Editor configuration via LSP

If your client supports [`workspace/configuration`](#workspace-configuration-support),
you can configure JETLS in a client-specific manner.
As examples, we show the configuration methods for the VSCode extension `jetls-client`,
and the Zed extension [`aviatesk/zed-julia#avi/JETLS`](https://github.com/aviatesk/zed-julia/tree/avi/JETLS).

##### VSCode (`jetls-client` extension)
Configure JETLS in VSCode's settings.json file with `jetls-client.jetlsSettings` section:
> Example `.vscode/settings.json`:
```jsonc
{
  "jetls-client.jetlsSettings": {
    "full_analysis": {
      "debounce": 2.0
    },
    "testrunner": {
      "executable": "/custom/path/to/testrunner"
    },
    "formatter": "JuliaFormatter"
  }
}
```
See [`package.json`](./package.json) for the complete list of available VSCode
settings and their descriptions.

##### Zed ([`aviatesk/zed-julia#avi/JETLS`](https://github.com/aviatesk/zed-julia/tree/avi/JETLS) extension)
Configure JETLS in Zed's settings.json file with the `lsp.JETLS.settings` section:
> Example `.zed/settings.json`:
```jsonc
{
  "lsp": {
    "JETLS": {
      // Required configuration items for starting the server
      "binary": {
        ...
      },
      // JETLS configurations
      "settings": {
        "full_analysis": {
          "debounce": 2.0
        },
        "testrunner": {
          "executable": "/custom/path/to/testrunner"
        },
        "formatter": "JuliaFormatter"
      }
    }
  }
}
```

### Configuration priority

When multiple configuration sources are present, they are merged in priority
order (highest first):

1. Project-specific `.JETLSConfig.toml`
2. Editor configuration via LSP
3. Built-in defaults

The `.JETLSConfig.toml` file takes precedence, since it provides a
**client-agnostic** way to configure JETLS that works consistently across
all editors.

## Formatting

JETLS provides document formatting support through integration with external
formatting tools. By default, [Runic.jl](https://github.com/fredrikekre/Runic.jl)
is used, but you can configure alternative formatters or use custom formatting
executables.

### Features

- **Document formatting**: Format entire Julia files
- **Range formatting**: Format selected code regions (Runic and custom
  formatters only)
- **Progress notifications**: Visual feedback during formatting operations
  for clients that support work done progress

### Prerequisites

JETLS supports preset formatters as well as custom formatting executables.
For preset formatters, install your preferred formatter and ensure it's
available in your system `PATH`:
- [Runic](https://github.com/fredrikekre/Runic.jl) (default):
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add("Runic")'
  ```
- [JuliaFormatter](https://github.com/domluna/JuliaFormatter.jl):
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add("JuliaFormatter")'
  ```

Note that you need to manually make `~/.julia/bin` available on the `PATH`
environment for the formatter executables to be accessible.
See <https://pkgdocs.julialang.org/dev/apps/> for the details.

For custom formatters, no installation is required—simply configure the path
to your executable in `.JETLSConfig.toml` (see the [custom formatter](#custom-formatter) section below).

### Formatter configuration

Configure the formatter using either a `.JETLSConfig.toml` file in your project
root or via LSP configuration (see [How to configure JETLS](#how-to-configure-jetls)
for details). The configuration supports three options:

#### Preset `"Runic"` (default)

```toml
formatter = "Runic"
```

In this case, JETLS will look for the `runic` executable and use it to perform formatting.

This is the default setting and doesn't require explicit configuration.
Runic supports both document and range formatting.

#### Preset `"JuliaFormatter"`

```toml
formatter = "JuliaFormatter"
```

In this case, JETLS will look for the `jlfmt` executable and use it to perform formatting.

If a [`.JuliaFormatter.toml` configuration](https://domluna.github.io/JuliaFormatter.jl/dev/config/)
file is found in your project, `jlfmt` will use those settings.
Otherwise, it uses default settings with formatting options provided by the
editor client (such as tab size) when available.

> [!WARNING]
> Note that JuliaFormatter currently, as of v2.2.0, only supports full document
> formatting, not range formatting.

#### Custom formatter

```toml
[formatter.custom]
executable = "/path/to/custom-formatter"
executable_range = "/path/to/custom-range-formatter"
```

Custom formatters should accept Julia code via stdin and output formatted
code to stdout, following the same interface as `runic`:
- `executable`: Command for full document formatting. The formatter should
  read the entire Julia source code from stdin, format it completely, and
  write the formatted result to stdout. The exit code should be 0 on success.
- `executable_range`: Command for range formatting. The formatter should
  accept a `--lines=START:END` argument to format only the specified line
  range. It should read the entire document code from stdin and write the
  _entire document code_ to stdout with only the specified region formatted.
  The rest of the document must remain unchanged.

### Troubleshooting

If you see an error about the formatter not being found:
1. Ensure you've installed the formatter as described above
2. Check that the formatter executable is in your system `PATH` by running
   `which runic` or `which jlfmt`
3. For custom formatters, verify the executable path specified in your settings
4. Restart your editor to ensure it picks up the updated `PATH` or configuration

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
2. Check that `testrunner` is in your system `PATH` by running `which testrunner`:
   otherwise you may need to add `~/.julia/bin` to `PATH`
3. Restart your editor to ensure it picks up the updated `PATH`

Test execution requires that your file is saved and matches the on-disk version.
If you see a message asking you to save the file first, make sure to save your
changes before running tests.

## Development note

- [DEVELOPMENT.md](./DEVELOPMENT.md): Developer notes
- [AGENTS.md](./AGENTS.md): Specific coding rules (recommended reading for human developers as well)
