# [Diagnostic CLI](@id cli-check)

The `jetls check` command runs JETLS diagnostics on Julia files from the command
line, without requiring an editor or LSP client. This is useful for CI pipelines,
pre-commit hooks, and workflows where editor integration is not available.

For details on what each diagnostic code means, see the
[Diagnostic reference](@ref diagnostic/reference).

## [Basic usage](@id cli-check/usage)

```bash
# Check a package source file
jetls check src/SomePkg.jl

# Check multiple files
jetls check src/SomePkg.jl test/runtests.jl

# Check multiple files with multi threads
jetls --threads=4,2 -- check src/SomePkg.jl test/runtests.jl
```

## [Command reference](@id cli-check/reference)

> `jetls check --help`
```@eval
using JETLS
using Markdown
Markdown.parse('`'^3 * '\n' * JETLS.check_help_message * '\n' * '`'^3)
```

## [Input files and analysis mode](@id cli-check/input)

Currently, `jetls check` accepts only file paths as input (not directories).
The analysis mode is determined by the file's location within the directory
structure:

- **Package source files** (`src/SomePkg.jl`): Analyzed in package context with
  full type inference
- **Test files** (`test/*.jl`): Analyzed in test context
- **Standalone scripts**: Analyzed as scripts

For example, when analyzing package code, run `jetls check` from the package
root directory:

```bash
# Correct: run from package root
cd /path/to/MyPkg
jetls check src/SomePkg.jl

# Incorrect: running from src/ directory won't detect package context
cd /path/to/MyPkg/src
jetls check SomePkg.jl  # May not work as expected
```

The working directory (or `--root` path) is used to locate `Project.toml` for
package context detection and `.JETLSConfig.toml` for configuration.

## [Options](@id cli-check/options)

### [`--root=<path>`](@id cli-check/options/root)

Sets the root path for configuration file lookup and relative path display.
By default, the current working directory is used.

When specified, JETLS will:
- Look for `.JETLSConfig.toml` in the specified root directory
- Display file paths relative to this root in diagnostic output

```bash
# Use project root for configuration
jetls check --root=/path/to/project src/SomePkg.jl

# Useful when running from a different directory
cd /tmp && jetls check --root=/path/to/project /path/to/project/src/SomePkg.jl
```

### [`--context-lines=<n>`](@id cli-check/options/context-lines)

Controls how many lines of source code context are shown around each diagnostic.
Default is `2`.

```bash
# Show more context
jetls check --context-lines=5 src/SomePkg.jl

# Show no context (just the diagnostic line)
jetls check --context-lines=0 src/SomePkg.jl
```

### [`--exit-severity=<level>`](@id cli-check/options/exit-severity)

Sets the minimum severity level that causes a non-zero exit code. This is useful
for CI pipelines where you want to fail only on certain severity levels.

Available levels (from most to least severe):
- `error` - Only errors cause exit code 1
- `warn` (default) - Warnings and errors cause exit code 1
- `info` - Information, warnings, and errors cause exit code 1
- `hint` - All diagnostics cause exit code 1

```bash
# Only fail CI on errors
jetls check --exit-severity=error src/SomePkg.jl

# Fail CI on any diagnostic
jetls check --exit-severity=hint src/SomePkg.jl
```

### [`--show-severity=<level>`](@id cli-check/options/show-severity)

Sets the minimum severity level to display in the output. Diagnostics below this
level are hidden from the output but may still affect the exit code (depending
on `--exit-severity`).

Available levels (from most to least severe):
- `error` - Only show errors
- `warn` - Show warnings and errors
- `info` - Show information, warnings, and errors
- `hint` (default) - Show all diagnostics

```bash
# Only display warnings and errors (hide info and hints)
jetls check --show-severity=warn src/SomePkg.jl

# Show all diagnostics but only fail on errors
jetls check --show-severity=hint --exit-severity=error src/SomePkg.jl
```

### [`--progress=<mode>`](@id cli-check/options/progress)

Controls how progress is displayed during analysis.

Available modes:
- `auto` (default) - Uses spinner for interactive terminals, simple output
  otherwise
- `full` - Always show animated spinner with detailed progress
- `simple` - One line per file (e.g., `Analyzing [1/5] src/foo.jl...`)
- `none` - No progress output

```bash
# Suppress progress for cleaner CI logs
jetls check --progress=none src/SomePkg.jl

# Force simple output even in terminal
jetls check --progress=simple src/SomePkg.jl
```

### [Julia runtime flags](@id cli-check/options/julia-flags)

Since `jetls` is an executable Julia app, you can pass Julia runtime flags
before `--` to configure the Julia runtime. This is especially useful for
controlling threading behavior. JETLS's signature analysis phase is
parallelized, so increasing thread count may improve analysis performance.

```bash
# Run with 4 default threads and 2 interactive threads
jetls --threads=4,2 -- check src/SomePkg.jl
```

For more details on available runtime flags, see the [Pkg documentation on runtime flags](https://pkgdocs.julialang.org/v1/apps/#Runtime-Julia-Flags).

## [Configuration](@id cli-check/configuration)

`jetls check` loads `.JETLSConfig.toml` from the root path (specified by
`--root`, or the current working directory by default). This is the same
configuration file used by the language server, and includes:

- [Diagnostic severity overrides](@ref diagnostic/configuring)
- [Pattern-based diagnostic filtering](@ref config/diagnostic-patterns)
- [Path-specific rules](@ref config/diagnostic-patterns)

Example configuration to suppress certain diagnostics in CI:

> `.JETLSConfig.toml`

```toml
# Ignore unused arguments in test files
[[diagnostic.patterns]]
pattern = "lowering/unused-argument"
match_by = "code"
match_type = "literal"
severity = "off"
path = "test/**/*.jl"
```

For complete configuration options, see the [JETLS configuration](@ref config/schema) page.
