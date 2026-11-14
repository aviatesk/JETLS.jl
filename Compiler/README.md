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

[`snapshots.toml`](./snapshots.toml) and [`patches/`](./patches/) are the
source of truth for the snapshots. `snapshots.toml` records the upstream
repository and, for each snapshot, the upstream base commit, its upstream
branch, the patch directory, the destination, and the supported Julia version
range.

Each snapshot is the `Compiler` directory of its `base` commit with the
patches in its `patches` directory applied in file name order. `base` must be
reachable from `base-branch`, a long-lived upstream branch such as `master` or
a `release-*` branch, so that the commit stays fetchable. `base-branch` itself
is informational and is never followed automatically. The patches are in
`git format-patch` format and only touch the `Compiler` directory. Patches
that backport upstream changes keep the upstream PR number in their subject.
A snapshot without patches omits `patches`.

Version ranges are half-open: `runtime.lower` is included and `runtime.upper`
is excluded. Ranges must not overlap, but gaps may represent unsupported Julia
versions. When the running Julia version does not match any snapshot, the
generated entrypoint falls back to `Base.Compiler` with
[`src/fallback.jl`](./src/fallback.jl), in the same way as the registered
Compiler.jl does. JETLS does not support these versions, but this lets
TestRunner.jl, which JETLS runs tests with, work on them (e.g. nightly
builds of a Julia version that has no snapshot yet).

[`update-snapshots.jl`](./update-snapshots.jl) materializes the configured
sources under [`snapshots/`](./snapshots/) and regenerates
[`src/Compiler.jl`](./src/Compiler.jl). These generated files are committed so
that a fresh checkout and source archive are self-contained and require no
network access during package loading. Do not edit them directly.

## Updating snapshots

Edit and test patches as commits in a Julia repository rather than editing the
patch files directly. To check out a snapshot, run:

```sh
julia --startup-file=no Compiler/update-snapshots.jl --checkout=1.15 --repo=path/to/julia
```

This detaches the clean work tree at `path/to/julia` at the snapshot's `base`
and applies its patches with `git am`. Add, edit, or drop commits there. To
move the snapshot to a newer upstream commit, rebase the commits onto that
commit (e.g. `git rebase --onto origin/master <old base>`) and set `base` in
`snapshots.toml` to its full 40-character SHA. Then export the commits back to
the patch directory:

```sh
julia --startup-file=no Compiler/update-snapshots.jl --export=1.15 --repo=path/to/julia
```

This replaces the snapshot's patch files with the commits in `base..HEAD` that
touch the `Compiler` directory. Pass `--ref=REF` to export another revision.

Finally, regenerate the snapshots and entrypoint:

```sh
julia --startup-file=no Compiler/update-snapshots.jl
```

Verify that the committed files match the configuration with:

```sh
julia --startup-file=no Compiler/update-snapshots.jl --check
```
