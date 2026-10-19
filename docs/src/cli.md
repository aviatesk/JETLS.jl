# [The `jetls` executable](@id cli)

The `jetls` executable is the main entry point for JETLS, providing the
following commands:

- [`jetls serve`](@ref launching) - Start the language server for editor
  integration
- [`jetls check`](@ref cli-check) - Run diagnostics from the command line
- [`jetls test`](@ref testrunner/cli) - Run tests with TestRunner.jl from the
  command line
- [`jetls schema`](@ref config/schema-cli) - Print JSON Schema for JETLS
  configuration
- `jetls version` - Show version information

The executable is installed as an
[executable app](https://pkgdocs.julialang.org/dev/apps/) via Pkg.jl. See
[Installing the `jetls` executable](@ref index/server-installation/install)
for the installation and update instructions.

## [Command reference](@id cli/reference)

> `jetls --help`

```@eval
using JETLS
using Markdown
Markdown.parse('`'^3 * '\n' * JETLS.help_message * '\n' * '`'^3)
```

## [Julia runtime flags](@id cli/julia-flags)

Since `jetls` is an executable Julia app, you can pass Julia runtime flags
before `--` to configure the Julia runtime. This is especially useful for
controlling threading behavior. JETLS's signature analysis phase is
parallelized, so increasing thread count may improve analysis performance.

```bash
# Run with 4 default threads and 2 interactive threads
jetls --threads=4,2 -- check src/SomePkg.jl
```

For more details on available runtime flags, see the
[Pkg documentation on runtime flags](https://pkgdocs.julialang.org/v1/apps/#Runtime-Julia-Flags).
