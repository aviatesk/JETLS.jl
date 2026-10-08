module test_upstream

using Test
using MarkdownSource: MarkdownSource as MS

const FORK = MS.Markdown

# The upstream sources at the commit in `upstream.toml`, in the gitignored `upstream/`
const UPSTREAM = readchomp(addenv(
    `$(Base.julia_cmd()) --startup-file=no $(joinpath(@__DIR__, "..", "update-upstream.jl")) fetch`,
    "JULIA_LOAD_PATH" => "@stdlib"))
const MARKDOWN = joinpath(UPSTREAM, "stdlib", "Markdown")

# Add `takestring!` for Julia 1.12 to the module that `Markdown.jl` defines.
function with_takestring(@nospecialize(ex))
    ex isa Expr || return ex
    if ex.head === :module
        shim = :(@static if !isdefined(Base, :takestring!)
            takestring!(io::IOBuffer) = String(take!(io))
        end)
        return Expr(:module, ex.args[1], ex.args[2], Expr(:block, shim, ex.args[3].args...))
    end
    return Expr(ex.head, Any[with_takestring(arg) for arg in ex.args]...)
end

# The upstream Markdown standard library, unchanged, to compare the fork with
module Upstream end
Base.include(with_takestring, Upstream, joinpath(MARKDOWN, "src", "Markdown.jl"))
const UpstreamMarkdown = Upstream.Markdown

#########################
# Checking source spans #
#########################

span_text(source::String, span::MS.Span) =
    String(codeunits(source)[span.first:span.past_last-1])

isnewline(byte::UInt8) = byte == UInt8('\n') || byte == UInt8('\r')

# Whether `text` is `source` with some bytes, such as the markers of nested lines, left out,
# and with line ends normalized, starting and ending with the same bytes as `source`
function embeds(text::String, source::String)
    a, b = codeunits(text), codeunits(source)
    isempty(a) && return isempty(b)
    isempty(b) && return false
    matches(x, y) = x == y || (x == UInt8('\n') && y == UInt8('\r'))
    matches(a[1], b[1]) || return false
    a[end] == b[end] || (a[end] == UInt8('\n') && isnewline(b[end])) || return false
    i = 1
    for j in eachindex(b)
        i > length(a) && break
        if matches(a[i], b[j])
            # Skip the `\r` of a `\r\n` that became `\n`.
            a[i] == UInt8('\n') && b[j] == UInt8('\r') && j < length(b) &&
                b[j+1] == UInt8('\n') && continue
            i += 1
        end
    end
    return i > length(a)
end

# Strings returned by inline parsers instead of the text as written
replaced_text(item::String, text::String) =
    text == "\\" * item || (startswith(text, '&') && endswith(text, ';')) ||
    (text, item) in (("--", "–"), ("---", "—"))

function content_problem(doc::MS.Document, @nospecialize(element), text::String)
    map = MS.content_map(doc, element)
    map === nothing && return isempty(strip(text)) ? nothing : "no content map"
    bytes = codeunits(text)
    covered = falses(length(bytes))
    for segment in map.segments
        for k in 0:segment.length-1
            i = segment.offset + k + 1
            1 ≤ i ≤ length(bytes) || return "content map out of bounds"
            x, y = bytes[i], codeunit(doc.source, segment.first + k)
            # `inline_code` replaces line ends by spaces.
            x == y || (x == UInt8(' ') && isnewline(y)) ||
                return "content byte $i is $(repr(Char(y))) in the source"
            covered[i] = true
        end
    end
    all(i -> covered[i] || isnewline(bytes[i]), eachindex(bytes)) ||
        return "content not covered by its map"
    return nothing
end

# What the source text of `item`, an item of a vector holding `context` items, should be
function item_problem(doc::MS.Document, @nospecialize(item), span::MS.Span, context::Symbol)
    context in (:block, :inline) || return nothing
    text = span_text(doc.source, span)
    if item isa String
        context === :inline || return "string block"
        embeds(item, text) || replaced_text(item, text) || return "unexpected text"
    elseif item isa FORK.Header
        startswith(text, '#') || all(in("=- \t"), last(split(text, '\n'))) ||
            return "unexpected header"
    elseif item isa Union{FORK.Code,FORK.LaTeX}
        problem = content_problem(doc, item, item isa FORK.Code ? item.code : item.formula)
        problem === nothing || return problem
        fence = first(text, 3)
        if context === :inline || startswith(text, '$')
            delimiter = first(text)
            (delimiter in "`\$" && endswith(text, delimiter)) || return "unexpected delimiters"
        elseif fence in ("```", "~~~")
            endswith(text, fence[1]) || return "unclosed fence"
        end
    elseif item isa Union{FORK.Italic,FORK.Bold,FORK.Strikethrough}
        delimiter = first(text, item isa FORK.Bold ? 2 : 1)
        (first(delimiter) in "*_~" && all(==(first(delimiter)), delimiter) &&
            endswith(text, delimiter)) || return "unexpected delimiters"
    elseif item isa Union{FORK.Link,FORK.Image}
        parts = MS.link_spans(doc, item)
        parts === nothing && return "no link spans"
        url = span_text(doc.source, parts.url)
        if startswith(text, '<')
            # An autolink, whose text is its destination
            parts.text == parts.url == MS.Span(span.first + 1, span.past_last - 1) ||
                return "unexpected link spans"
            item.url in (url, "mailto:" * url) || return "url $(repr(url))"
        else
            span.first ≤ parts.text.first ≤ parts.text.past_last ≤ parts.url.first ≤
                parts.url.past_last ≤ span.past_last || return "unexpected link spans"
            if item isa FORK.Link
                startswith(text, '[') && endswith(text, ')') || return "unexpected delimiters"
                FORK.replace_escapes_and_entities(url) == item.url || return "url $(repr(url))"
            else
                startswith(text, "![") && endswith(text, ')') || return "unexpected delimiters"
                url == item.url || return "url $(repr(url))"
                span_text(doc.source, parts.text) == item.alt || return "alternative text"
            end
        end
    elseif item isa FORK.Footnote
        startswith(text, "[^") || return "unexpected footnote"
    elseif item isa FORK.LineBreak
        first(text) in "\\<" || return "unexpected line break"
    elseif item isa FORK.HTMLInline
        embeds(item.content, text) || return "unexpected HTML"
    elseif item isa Union{FORK.BlockQuote,FORK.Admonition}
        startswith(text, item isa FORK.BlockQuote ? ">" : "!!!") || return "unexpected start"
    elseif item isa FORK.List
        first(text) in "-+*0123456789" || return "unexpected list marker"
    elseif item isa FORK.Table
        '|' in text || return "unexpected table"
    elseif item isa FORK.HorizontalRule
        # With `\r` line ends, consecutive rules make up one line.
        all(c -> c in "*-_" || isspace(c), text) || return "unexpected rule"
    elseif item isa FORK.HTMLBlock
        startswith(text, '<') || return "unexpected HTML"
    elseif !(item isa FORK.Paragraph)
        # Interpolated values
        startswith(text, '$') || return "unexpected $(typeof(item))"
    end
    return nothing
end

# The vectors nested in `item`, with the span each is within and what its items are
function nested(doc::MS.Document, @nospecialize(item), span::MS.Span, context::Symbol)
    context === :items && return ((item, span, :block),)
    context === :rows && return ((item, span, :cells),)
    context === :cells && return ((item, span, :inline),)
    if item isa FORK.Paragraph
        return ((item.content, span, :inline),)
    elseif item isa Union{FORK.Header,FORK.Italic,FORK.Bold,FORK.Strikethrough}
        return item.text isa AbstractVector ? ((item.text, span, :inline),) : ()
    elseif item isa FORK.Link
        parts = MS.link_spans(doc, item)
        return parts === nothing ? () : ((item.text, parts.text, :inline),)
    elseif item isa FORK.Footnote
        return item.text isa AbstractVector ? ((item.text, span, :block),) : ()
    elseif item isa Union{FORK.BlockQuote,FORK.Admonition}
        return ((item.content, span, :block),)
    elseif item isa FORK.List
        return ((item.items, span, :items),)
    elseif item isa FORK.Table
        return ((item.rows, span, :rows),)
    end
    return ()
end

# Check that `items`, of `context` items, have spans in order within `parent`, which cover
# the source text they are parsed from.
function check_items!(problems::Vector{String}, doc::MS.Document, items::AbstractVector,
                      parent::MS.Span, context::Symbol)
    spans = MS.spans(doc, items)
    if spans === nothing
        isempty(items) || push!(problems, "no spans for $(summary(items)) in $context")
        return problems
    elseif length(spans) != length(items)
        push!(problems, "$(length(spans)) spans for $(summary(items)) in $context")
        return problems
    end
    previous = parent.first
    for (item, span) in zip(items, spans)
        label = "$(item isa AbstractVector ? "item" : nameof(typeof(item))) in $context"
        if !(parent.first ≤ span.first ≤ span.past_last ≤ parent.past_last)
            push!(problems, "$label at $span is outside of $parent")
            continue
        end
        span.first ≥ previous || push!(problems, "$label at $span overlaps the previous item")
        previous = span.past_last
        problem = item_problem(doc, item, span, context)
        problem === nothing ||
            push!(problems, "$label $(repr(span_text(doc.source, span))): $problem")
        for (children, within, children_context) in nested(doc, item, span, context)
            check_items!(problems, doc, children, within, children_context)
        end
    end
    return problems
end

span_problems(doc::MS.Document) = check_items!(String[], doc, doc.md.content,
    MS.Span(1, ncodeunits(doc.source) + 1), :block)

###########################
# Agreement with upstream #
###########################

# Whether the fork's tree `a` has the same structure and values as the upstream tree `b`
function same(@nospecialize(a), @nospecialize(b))
    if a isa AbstractVector
        b isa AbstractVector && length(a) == length(b) || return false
        return all(i -> same(a[i], b[i]), eachindex(a, b))
    elseif parentmodule(typeof(a)) === FORK
        T, U = typeof(a), typeof(b)
        (nameof(T) === nameof(U) && parentmodule(U) === UpstreamMarkdown &&
            T.parameters == U.parameters) || return false
        for name in fieldnames(T)
            name === :meta && continue
            same(getfield(a, name), getfield(b, name)) || return false
        end
        return true
    end
    return isequal(a, b)
end

describe(@nospecialize(err)) = sprint(showerror, err)

# The fork must parse `source` exactly as the upstream parser does, and record valid spans.
function source_problems(source::String, flavor::Symbol)
    expected = try
        UpstreamMarkdown.parse(source; flavor)
    catch err
        err
    end
    actual = try
        MS.parse(source; flavor)
    catch err
        err
    end
    if expected isa Exception
        actual isa Exception && describe(actual) == describe(expected) && return String[]
        return ["$(actual isa Exception ? describe(actual) : "parsed"), but upstream: $(describe(expected))"]
    end
    actual isa Exception && return ["$(describe(actual)), but upstream parses"]
    same(actual.md.content, expected.content) || return ["parsed differently from upstream"]
    return span_problems(actual)
end

function problems_by_source(sources)
    problems = Dict{Tuple{String,Symbol},Vector{String}}()
    for (source, flavor) in sources
        found = try
            source_problems(source, flavor)
        catch err
            ["checking threw $(describe(err))"]
        end
        isempty(found) || (problems[(source, flavor)] = found)
    end
    return problems
end

with_line_ends(sources) = unique!([(replace(source, "\n" => line_end), flavor)
    for (source, flavor) in sources for line_end in ("\n", "\r\n", "\r")])

function string_literals!(strings::Vector{String}, @nospecialize(ex))
    ex isa String && push!(strings, ex)
    ex isa Expr && foreach(arg -> string_literals!(strings, arg), ex.args)
    return strings
end

# The string literals of the upstream tests, e.g. the CommonMark spec examples and the
# contents of `md"..."`, in each flavor, and their plain renderings like the roundtrip tests
function upstream_test_sources()
    strings = String[]
    for file in readdir(joinpath(MARKDOWN, "test"); join=true)
        endswith(file, ".jl") && string_literals!(strings, Meta.parseall(read(file, String)))
    end
    sources = [(string, flavor) for string in unique!(strings)
        for flavor in (:common, :github, :julia)]
    for (source, flavor) in copy(sources)
        rendered = try
            UpstreamMarkdown.plain(UpstreamMarkdown.parse(source; flavor))
        catch
            continue
        end
        push!(sources, (rendered, flavor))
    end
    return unique!(sources)
end

# Docstrings without interpolations, e.g. those of `Base` and the standard libraries
function docstrings()
    sources = String[]
    for mod in Base.Docs.modules, multidoc in values(Base.Docs.meta(mod))
        for docstr in values(multidoc.docs)
            all(part -> part isa AbstractString, docstr.text) &&
                push!(sources, join(docstr.text))
        end
    end
    return unique!(sources)
end

@testset "upstream tests" begin
    sources = upstream_test_sources()
    @test length(sources) > 5000
    @test isempty(problems_by_source(with_line_ends(sources)))
end

@testset "docstrings" begin
    sources = docstrings()
    @test length(sources) > 1000
    @test isempty(problems_by_source(with_line_ends((source, :julia) for source in sources)))
end

@testset "documents" begin
    files = [joinpath(MARKDOWN, "docs", "src", "index.md"), joinpath(@__DIR__, "..", "README.md")]
    sources = [(read(file, String), flavor) for file in files
        for flavor in (:common, :github, :julia)]
    @test isempty(problems_by_source(with_line_ends(sources)))
end

# E.g. `MARKDOWNSOURCE_TEST_CORPUS=~/.julia/packages` checks the Markdown files there.
corpus = get(ENV, "MARKDOWNSOURCE_TEST_CORPUS", "")
isempty(corpus) || @testset "corpus" begin
    files = String[joinpath(directory, filename)
        for root in split(corpus, Sys.iswindows() ? ';' : ':') if !isempty(root)
        for (directory, _, filenames) in walkdir(expanduser(root); onerror=Returns(nothing))
        for filename in filenames if endswith(filename, ".md")]
    @test isempty(problems_by_source((read(file, String), :julia) for file in files))
end

end # module test_upstream
