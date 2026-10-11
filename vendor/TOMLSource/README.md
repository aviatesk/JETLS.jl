# TOMLSource

[![](https://github.com/aviatesk/JETLS.jl/actions/workflows/TOMLSource.jl.yml/badge.svg)](https://github.com/aviatesk/JETLS.jl/actions/workflows/TOMLSource.jl.yml)
[![](https://codecov.io/gh/aviatesk/JETLS.jl/branch/master/graph/badge.svg?flag=TOMLSource.jl)](https://codecov.io/gh/aviatesk/JETLS.jl&flags[0]=TOMLSource.jl)

TOML parsing with source locations, for diagnostics and code actions on files
such as `Project.toml` and `.JETLSConfig.toml`.

`TOMLSource.parse` returns a `Document` whose `data` holds the parsed values,
as `TOML.parse` returns them, and whose `items` map the path of each item,
e.g. `["deps", "JET"]`, to the spans of its key and value. Edits are computed
against the original text, so comments and layout outside the edited span are
kept, and each edit is checked by reparsing the edited text:

```julia
using TOMLSource

doc = TOMLSource.parse(read("Project.toml", String))
TOMLSource.key_span(doc, ["deps", "JET"])
edit = TOMLSource.insert_table_entry(doc, ["compat"], "JET", "0.11")
```

## Parser

`src/parser.jl` is a fork of Julia's `base/toml/parser.jl`, so values and
syntax errors match what Pkg and code loading see. Besides a `takestring!`
replacement for Julia 1.12, the fork only adds the `items`, `item_path`, and
`key_spans` fields, the "Source locations" section, and calls to it guarded by
`l.items === nothing`.

`upstream.toml` records the upstream commit the fork is based on.
`update-upstream.jl` fetches the upstream parser, printer, TOML stdlib, and
its tests at that commit into the gitignored `upstream/` directory, and shows
the local changes with `diff`:

```sh
julia --startup-file=no TOMLSource/update-upstream.jl diff
```

`test/test_upstream.jl` runs the upstream tests against the fork with source
locations recorded, and checks that the fork parses every input of those
tests, the toml-test suite included, exactly as the upstream parser does, with
spans that match the parsed data. Setting `TOMLSOURCE_TEST_CORPUS` to
directories, separated by `:` (`;` on Windows), also checks the TOML files in
them, e.g. those of a depot.

To update the fork to an upstream commit, run:

```sh
julia --startup-file=no TOMLSource/update-upstream.jl update <commit>
```

This merges the upstream changes to the parser into `src/parser.jl` with
`git merge-file`, leaving conflict markers where they overlap the local
changes, and records the commit in `upstream.toml`.
