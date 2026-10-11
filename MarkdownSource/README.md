# MarkdownSource

[![](https://github.com/aviatesk/JETLS.jl/actions/workflows/MarkdownSource.jl.yml/badge.svg)](https://github.com/aviatesk/JETLS.jl/actions/workflows/MarkdownSource.jl.yml)
[![](https://codecov.io/gh/aviatesk/JETLS.jl/branch/master/graph/badge.svg?flag=MarkdownSource.jl)](https://codecov.io/gh/aviatesk/JETLS.jl&flags[0]=MarkdownSource.jl)

Markdown parsing with source locations, for language features on docstrings
and Documenter pages, such as navigating `@ref` links.

`MarkdownSource.parse` returns a `Document` whose `md` is the `MD` that
`Markdown.parse` returns, and which records where its elements are in the
source: the span of every element, including the strings of text between inline
elements, the spans of the text and the destination of links, and where the
code of code blocks and inline code comes from:

```julia
using MarkdownSource: MarkdownSource as MS

doc = MS.parse("See [`foo`](@ref) and [the bar](@ref Foo.bar).")
MS.foreach_element(doc) do element, span
    element isa MS.Markdown.Link || return
    parts = MS.link_spans(doc, element)  # `parts.text` and `parts.url`
end
```

Spans are 1-based byte offsets into the source. Nested blocks, such as those
in block quotes, admonitions, and list items, are parsed from their lines
without their markers, so the code of a code block in them may come from
separate parts of the source; `content_map` and `source_span` map it back.

## Parser

`src/Markdown` is a fork of the parser of Julia's `Markdown` standard library,
`stdlib/Markdown/src` without `Markdown.jl` and the renderers, so documents
parse exactly as `Markdown.parse` parses docstrings and Documenter pages. It
defines its own element types, e.g. `MarkdownSource.Markdown.Link`, which are
distinct from those of the standard library. Besides dropping the renderers,
the fork only adds calls to the hooks in `src/sourcemap.jl`: the parser reads
nested content from new streams, and the hooks record where each stream comes
from in the source.

`upstream.toml` records the upstream commit the fork is based on.
`update-upstream.jl` fetches the upstream Markdown standard library, its
documentation, and its tests at that commit into the gitignored `upstream/`
directory, and shows the local changes with `diff`:

```sh
julia --startup-file=no MarkdownSource/update-upstream.jl diff
```

`test/test_upstream.jl` checks that the fork, with source locations recorded,
parses exactly as the upstream parser does, so that the upstream tests would
pass with the fork, and that every span covers what its element is parsed
from. Its inputs are the string literals of the upstream tests, the CommonMark
spec examples included, in each flavor, their plain renderings, as the upstream
roundtrip tests parse, and the docstrings of the loaded modules, each with
`\n`, `\r\n`, and `\r` line ends. Setting `MARKDOWNSOURCE_TEST_CORPUS` to
directories, separated by `:` (`;` on Windows), also checks the Markdown files
in them, e.g. those of a depot.

To update the fork to an upstream commit, run:

```sh
julia --startup-file=no MarkdownSource/update-upstream.jl update <commit>
```

This merges the upstream changes to the forked files into `src/Markdown` with
`git merge-file`, leaving conflict markers where they overlap the local
changes, reports upstream files added since, and records the commit in
`upstream.toml`.
