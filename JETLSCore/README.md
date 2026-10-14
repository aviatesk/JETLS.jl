# JETLSCore

[![](https://github.com/aviatesk/JETLS.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/aviatesk/JETLS.jl/actions/workflows/ci.yml)
[![](https://codecov.io/gh/aviatesk/JETLS.jl/branch/master/graph/badge.svg?flag=JETLS.jl)](https://codecov.io/gh/aviatesk/JETLS.jl&flags[0]=JETLS.jl)

This package implements the JETLS language server and the `jetls check`,
`jetls serve`, and `jetls test` commands.

It is not meant to be used directly: the `JETLS` package at the
[repository root](../) is the entry point of the `jetls` app, which handles
`--version`, `schema`, and the help messages by itself and loads this package
only for the other commands, so that these stay fast.
See the [user guide](https://aviatesk.github.io/JETLS.jl/) for using JETLS,
and [DEVELOPMENT.md](../DEVELOPMENT.md) for developing it.

The development preferences described in DEVELOPMENT.md, such as
`JETLS_DEV_MODE`, are preferences of this package, so set them in a
`[JETLSCore]` section of `LocalPreferences.toml`.

## Tests

The tests of this package are in [`test/`](./test/). Run them from the
repository root with:

```bash
julia --startup-file=no --project=JETLSCore -e 'using Pkg; Pkg.test()'
```

The tests of the `jetls` app commands are in the root [`test/`](../test/).
