# [Formatter integration](@id formatting)

JETLS provides document formatting support through integration with external
formatting tools. By default, [Runic.jl](https://github.com/fredrikekre/Runic.jl)
is used, but you can configure alternative formatters or use custom formatting
executables.

## [Features](@id formatting/features)

- **Document formatting**: Format entire Julia files
  (`textDocument/formatting`)
- **Range formatting**: Format one selected region
  (`textDocument/rangeFormatting`)
- **Multiple range formatting**: Format multiple selected regions in one
  LSP 3.18 request (`textDocument/rangesFormatting`). This is advertised only
  when the client supports `textDocument.rangeFormatting.rangesSupport`.
- **Progress notifications**: Visual feedback during formatting operations
  for clients that support work done progress

## [Prerequisites](@id formatting/prerequisites)

JETLS supports preset formatters as well as custom formatting executables.
For preset formatters, install your preferred formatter and ensure it's
available in your system `PATH`:

- [Runic](https://github.com/fredrikekre/Runic.jl) (default):
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add("Runic")'
  ```

- [JuliaFormatter](https://github.com/domluna/JuliaFormatter.jl)
  (requires [v2.2.0](https://github.com/domluna/JuliaFormatter.jl/releases/tag/v2.2.0) or higher):
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add("JuliaFormatter")'
  ```

Note that you need to manually make `~/.julia/bin` available on the `PATH`
environment for the formatter executables to be accessible.
See <https://pkgdocs.julialang.org/dev/apps/> for the details.

For custom formatters, no installation is required—simply configure the path
to your executable in `.JETLSConfig.toml` (see the
[custom formatter](#formatting/configuration/custom) section below).

## [Formatter configuration](@id formatting/configuration)

Configure the formatter using either a `.JETLSConfig.toml` file in your project
root or via LSP configuration (see [How to configure JETLS](@ref) for details).
The configuration supports three options:

### [Preset `"Runic"` (default)](@id formatting/configuration/runic)

```toml
formatter = "Runic"
```

In this case, JETLS will look for the `runic` executable and use it to perform
formatting.

This is the default setting and doesn't require explicit configuration.
Runic supports document formatting (`textDocument/formatting`), single range
formatting (`textDocument/rangeFormatting`), and multiple range formatting
(`textDocument/rangesFormatting`).

### [Preset `"JuliaFormatter"`](@id formatting/configuration/juliaformatter)

```toml
formatter = "JuliaFormatter"
```

In this case, JETLS will look for the `jlfmt` executable and use it to perform
formatting.

If a [`.JuliaFormatter.toml` configuration](https://domluna.github.io/JuliaFormatter.jl/dev/config/)
file is found in your project, `jlfmt` will use those settings.
Otherwise, it uses default settings with formatting options provided by the
editor client (such as tab size) when available.

JuliaFormatter supports document formatting (`textDocument/formatting`), single
range formatting (`textDocument/rangeFormatting`), and multiple range formatting
(`textDocument/rangesFormatting`).

!!! note
    Range formatting (and multiple range formatting) requires
    [JuliaFormatter v2.7.0](https://github.com/JuliaEditorSupport/JuliaFormatter.jl/releases/tag/v2.7.0)
    or later, which adds the `--lines` flag to the `jlfmt` CLI.
    Range formatting requests fail with earlier versions.

### [Custom formatter](@id formatting/configuration/custom)

```toml
[formatter.custom]
executable = "/path/to/custom-formatter"
executable_range = "/path/to/custom-range-formatter"
```

Custom formatters should accept Julia code via stdin and output formatted
code to stdout, following the same interface as `runic`:

- `executable`: Command for document formatting (`textDocument/formatting`).
  The formatter should read the entire Julia source code from stdin, format it
  completely, and write the formatted result to stdout. The exit code should be
  0 on success.
- `executable_range`: Command for single and multiple range formatting
  (`textDocument/rangeFormatting` and `textDocument/rangesFormatting`). The
  formatter should accept one or more `--lines=START:END` arguments to format
  only the specified line ranges. It should read the entire document code from
  stdin and write the _entire document code_ to stdout with only the specified
  regions formatted. The rest of the document must remain unchanged.

## [Troubleshooting](@id formatting/troubleshooting)

If you see an error about the formatter not being found:

1. Ensure you've installed the formatter as described above
2. Check that the formatter executable is in your system `PATH` by running
   `which runic` or `which jlfmt`
3. For custom formatters, verify the executable path specified in your settings
4. Restart your editor to ensure it picks up the updated `PATH` or configuration
