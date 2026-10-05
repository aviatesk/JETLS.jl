# [Diagnostic CLI](@id cli-check)

The `jetls check` command runs JETLS diagnostics on Julia files from the command
line, without requiring an editor or LSP client. This is useful for CI pipelines,
pre-commit hooks, and workflows where editor integration is not available.

For details on what each diagnostic code means, see the
[Diagnostic reference](@ref diagnostic/reference).

## [Basic usage](@id cli-check/usage)

```bash
# Check the package in the current directory
jetls check

# Check a package in another directory
jetls check /path/to/SomePkg

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

## [Input paths and analysis mode](@id cli-check/input)

`jetls check` accepts Julia files and package directories as input.

A package directory is a directory whose `Project.toml` has a `name` entry.
It is analyzed through its package entry file `src/<name>.jl`. Test files are
not included; pass `test/runtests.jl` as well to analyze them. Other
directories, including subdirectories of a package such as `src/`, are
rejected.

When no path is given, the package at the root path (the current working
directory by default) is analyzed.

For files, the analysis mode is determined by the file's location within the
directory structure:

- **Package source files** (`src/SomePkg.jl`): Analyzed in package context with
  full type inference
- **Test files** (`test/*.jl`): Analyzed in test context
- **Standalone scripts**: Analyzed as scripts

The package context is detected from the nearest `Project.toml` above each
file, regardless of the working directory. The root path only determines where
`.JETLSConfig.toml` is loaded from and how paths are displayed (see
[`--root`](@ref cli-check/options/root)).

## [Options](@id cli-check/options)

### [`--root=<path>`](@id cli-check/options/root)

Sets the root path for configuration file lookup and relative path display.
By default, the package directory is used when exactly one
[package directory](@ref cli-check/input) is given, and the current working
directory otherwise.

When specified, JETLS will:

- Look for `.JETLSConfig.toml` in the specified root directory
- Resolve relative input paths against this root
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

After analysis completes, the final line reports whether the check passed or
failed and the exit severity used.

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

Sets the minimum severity level to display in the output. The default is
`info`, independently of [`--exit-severity`](@ref cli-check/options/exit-severity).
Diagnostics below the display threshold are hidden but may still affect the
exit code. The summary includes counts of hidden diagnostics by severity
and indicates how to display them.

Available levels (from most to least severe):

- `error` - Only show errors
- `warn` - Show warnings and errors
- `info` (default) - Show information, warnings, and errors
- `hint` - Show all diagnostics

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

`jetls check` loads `.JETLSConfig.toml` from the root path (see
[`--root`](@ref cli-check/options/root) for its default). This is the same
configuration file used by the language server, and includes:

- [Diagnostic severity overrides](@ref diagnostic/configuring)
- [Pattern-based diagnostic filtering](@ref config/diagnostic/patterns)
- [Path-specific rules](@ref config/diagnostic/patterns)

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

Package environments that are not instantiated yet (e.g. a fresh clone in CI)
are resolved and instantiated before analysis. `jetls check` has no client to
confirm with, so the default
[`auto_instantiate = "prompt"`](@ref config/full_analysis/auto_instantiate)
behaves like `"always"` here. Set it to `"never"` in `.JETLSConfig.toml` to
analyze against the environment as is.

For complete configuration options, see the [JETLS configuration](@ref config/schema) page.

## [GitHub Actions](@id cli-check/github-actions)

A composite action is available for running `jetls check` in CI pipelines.
This handles Julia setup, caching, and JETLS installation automatically.

### Basic usage

```yaml
steps:
  - uses: actions/checkout@v6
  - uses: aviatesk/JETLS.jl/.github/actions/check@release
```

Without `files`, this checks the package at the repository root.

### With options

```yaml
steps:
  - uses: actions/checkout@v6
  - uses: aviatesk/JETLS.jl/.github/actions/check@release
    with:
      files: src/SomePkg.jl test/runtests.jl
      exit-severity: error
      show-severity: warn
```

### Action inputs

All `jetls check` command-line options are available as action inputs:

| Input           | Default   | Description                                                   |
| :-------------- | :-------- | :------------------------------------------------------------ |
| `files`         |           | Space-separated list of files or package directories to check |
| `version`       | `release` | JETLS revision to install                                     |
| `julia-version` | `1.13`    | Julia version to use                                          |
| `quiet`         | `true`    | Suppress info and warning log messages                        |
| `root`          |           | Root directory for configuration and relative paths           |
| `context-lines` | `2`       | Number of source context lines                                |
| `exit-severity` | `warn`    | Minimum severity to trigger non-zero exit                     |
| `show-severity` | `info`    | Minimum severity to display                                   |
| `progress`      | `none`    | Progress display mode                                         |

See [`.github/actions/check/action.yml`](https://github.com/aviatesk/JETLS.jl/blob/release/.github/actions/check/action.yml)
for the full action definition.
