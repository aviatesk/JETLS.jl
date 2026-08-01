# Compiler.jl snapshots

This directory defines the `Compiler` package used by the JETLS stack. It pins
a Compiler.jl implementation for each supported Julia runtime range and selects
the matching implementation when the package is loaded.

## Package identity

The UUID in [`Project.toml`](./Project.toml) intentionally matches
[JuliaLang/BaseCompiler.jl](https://github.com/JuliaLang/BaseCompiler.jl):

```toml
uuid = "807dbc54-b67e-4c79-8afb-eafe4df6f2e1"
```

In the development environment, the JETLS root project resolves this package
identity to the local `Compiler` directory. Dependencies in the JETLS stack
that use `Compiler` declare the same UUID, so Julia loads this package for all
of them. The generated entrypoint can therefore select one runtime-compatible
Compiler.jl implementation for the entire stack. Keeping this UUID equal to
the upstream Compiler UUID is the central invariant of the development setup.

During [release vendoring](../DEVELOPMENT.md#release-process), the UUID is
rewritten to a deterministic, JETLS-specific UUID. The release process
rewrites the package UUID, the UUID embedded in every snapshot's `Compiler`
module, and dependency references
throughout the vendored JETLS stack. Applying the rewrite consistently
preserves one shared package identity inside the stack while isolating it from
packages in the user's environment that use the upstream Compiler UUID.

## Snapshot sources

[`snapshots.toml`](./snapshots.toml) is the source of truth for the
snapshots. It records the upstream repository and, for each snapshot, the exact
commit, provenance branch, destination, and supported Julia version range.
The commit and version range control generation. `source-branch` is
informational and is never followed automatically.

Version ranges are half-open: `runtime.lower` is included and `runtime.upper`
is excluded. Ranges must not overlap, but gaps may represent unsupported Julia
versions. The generated entrypoint reports the supported ranges when the
running Julia version does not match any snapshot.

[`update-snapshots.jl`](./update-snapshots.jl) materializes the configured
sources under [`snapshots/`](./snapshots/) and regenerates
[`src/Compiler.jl`](./src/Compiler.jl). These generated files are committed so
that a fresh checkout and source archive are self-contained and require no
network access during package loading. Do not edit them directly.

## Updating snapshots

Edit `snapshots.toml`, using a full 40-character commit SHA, then regenerate the
snapshots and entrypoint:

```sh
julia --startup-file=no Compiler/update-snapshots.jl
```

Verify that the committed files match the configuration with:

```sh
julia --startup-file=no Compiler/update-snapshots.jl --check
```
