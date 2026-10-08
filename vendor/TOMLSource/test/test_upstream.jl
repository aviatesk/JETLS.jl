module test_upstream

using Test
using Dates: Dates
using TOMLSource: TOMLSource as TS

# The upstream sources at the commit in `upstream.toml`, in the gitignored `upstream/`
const UPSTREAM = readchomp(addenv(
    `$(Base.julia_cmd()) --startup-file=no $(joinpath(@__DIR__, "..", "update-upstream.jl")) fetch`,
    "JULIA_LOAD_PATH" => "@stdlib"))

# The upstream parser, unchanged, to compare the fork with
module Upstream
@static if !isdefined(Base, :takestring!)
    takestring!(io::IOBuffer) = String(take!(io))
end
end
Base.include(Upstream, joinpath(UPSTREAM, "base", "toml", "parser.jl"))

# Stands in for `Base.TOML` in the upstream TOML stdlib and its tests: the fork's parser,
# recording source locations, and the upstream printer, assembled like `base/toml/toml.jl`
module ForkTOML
using TOMLSource: TOMLSource as TS
for name in names(TS.BaseTOML; all=true)
    Base.isidentifier(name) || continue
    name in (:BaseTOML, :eval, :include, :parse, :tryparse) && continue
    @eval using TOMLSource.BaseTOML: $name
end

# Sources parsed through the TOML stdlib, labeled with their files if any, to be compared
# with the upstream parser
const sources = Pair{String,String}[]

function recording(p::TS.BaseTOML.Parser)
    p.items === nothing && (p.items = Dict{TS.Path,TS.Item}())
    push!(sources, something(p.filepath, first(p.str, 200)) => p.str)
    return p
end
parse(p::TS.BaseTOML.Parser) = TS.BaseTOML.parse(recording(p))
tryparse(p::TS.BaseTOML.Parser) = TS.BaseTOML.tryparse(recording(p))

module Printer end
end

# The upstream tests run in a module of their own, like `Main` upstream.
module UpstreamTests end

# `using` cannot take a module object, so a module importing from `Base.TOML` gets an alias of
# `ForkTOML` to import from.
const BASE_TOML_ALIAS = Symbol("#Base.TOML#")

# `precompile.jl` of the TOML stdlib is not fetched, and `print.jl` tests the printer alone,
# with output depending on the `Dict` order of the Julia version upstream targets.
const SKIPPED_FILES = ("precompile.jl", "print.jl")

# Adapt upstream code to the fork and the running Julia: refer to `ForkTOML` for `Base.TOML`,
# import the TOML stdlib from `UpstreamTests`, and leave out what needs a newer `Test`.
function adapt(@nospecialize(ex))
    ex isa Expr || return ex
    if Meta.isexpr(ex, :., 2) && ex.args == Any[:Base, QuoteNode(:TOML)]
        return ForkTOML
    elseif ex.head === :using || ex.head === :import
        return Expr(ex.head, Any[adapt_path(arg) for arg in ex.args]...)
    elseif Meta.isexpr(ex, :call, 2) && ex.args[1] === :include
        ex.args[2] in SKIPPED_FILES && return nothing
        return Expr(:call, :include, adapt, ex.args[2])
    elseif Meta.isexpr(ex, :macrocall) && ex.args[1] === Symbol("@test")
        uses_missing_test_function(ex) &&
            return Expr(:macrocall, Symbol("@test_skip"), ex.args[2], ex.args[3])
        # The `context` keyword, only used for failure messages, is new in Julia 1.14.
        args = filter(arg -> !(Meta.isexpr(arg, :(=)) && arg.args[1] === :context), ex.args)
        return Expr(:macrocall, Any[adapt(arg) for arg in args]...)
    end
    args = Any[adapt(arg) for arg in ex.args]
    ex.head === :module && pushfirst!(args[end].args, :(const $BASE_TOML_ALIAS = $ForkTOML))
    return Expr(ex.head, args...)
end

function adapt_path(@nospecialize(arg))
    if Meta.isexpr(arg, :(:))
        return Expr(:(:), adapt_path(arg.args[1]), arg.args[2:end]...)
    elseif Meta.isexpr(arg, :.) && arg.args[1] === :TOML
        return Expr(:., :., arg.args...)
    elseif Meta.isexpr(arg, :.) && length(arg.args) ≥ 2 && arg.args[1:2] == Any[:Base, :TOML]
        return Expr(:., :., BASE_TOML_ALIAS, arg.args[3:end]...)
    end
    return arg
end

function uses_missing_test_function(@nospecialize(ex))
    ex isa Expr || return false
    Meta.isexpr(ex, :., 2) && ex.args[1] === :Test && ex.args[2] isa QuoteNode &&
        return !isdefined(Test, ex.args[2].value)
    return any(uses_missing_test_function, ex.args)
end

Base.include(adapt, ForkTOML.Printer, joinpath(UPSTREAM, "base", "toml", "printer.jl"))

# The upstream Dates stdlib adds these methods to `Base.TOML.Printer`.
ForkTOML.Printer.printvalue(::Function, io::IO, value::Dates.Date, ::Bool) =
    Base.print(io, Dates.format(value, Dates.dateformat"YYYY-mm-dd"))
ForkTOML.Printer.printvalue(::Function, io::IO, value::Dates.Time, ::Bool) =
    Base.print(io, Dates.format(value, Dates.dateformat"HH:MM:SS.sss"))
ForkTOML.Printer.printvalue(::Function, io::IO, value::Dates.DateTime, ::Bool) =
    Base.print(io, Dates.format(value, Dates.dateformat"YYYY-mm-dd\THH:MM:SS.sss\Z"))
ForkTOML.Printer.is_valid_toml_value(::Union{Dates.Date,Dates.Time,Dates.DateTime}) = true

Base.include(adapt, UpstreamTests, joinpath(UPSTREAM, "stdlib", "TOML", "src", "TOML.jl"))

span_text(source::String, span::TS.Span) =
    String(codeunits(source)[span.first:span.past_last-1])

function data_paths!(paths::Set{TS.Path}, path::TS.Path, @nospecialize(value))
    push!(paths, copy(path))
    if value isa AbstractDict
        for (key, child) in value
            push!(path, key)
            data_paths!(paths, path, child)
            pop!(path)
        end
    elseif value isa AbstractVector
        for (index, child) in enumerate(value)
            push!(path, index)
            data_paths!(paths, path, child)
            pop!(path)
        end
    end
    return paths
end

# The keys of a document consisting of one header, e.g. `["a", "b"]` for `[[a.b]]`
function header_keys(data::Dict{String,Any})
    keys = String[]
    while length(data) == 1
        key, value = only(data)
        push!(keys, key)
        value isa AbstractVector && !isempty(value) && (value = last(value))
        value isa Dict{String,Any} || break
        data = value
    end
    return keys
end

# Check an item against the data: each span must be text that parses back to what the item
# names or holds.
function item_problem(doc::TS.Document, path::TS.Path, item::TS.Item)
    source = doc.source
    kind = item.kind
    for span in (item.key, item.value, item.entry)
        (span === nothing || kind === TS.ROOT_TABLE) && continue
        text = span_text(source, span)
        isempty(text) || !isspace(first(text)) && !isspace(last(text)) ||
            return "span $(repr(text)) has surrounding whitespace"
    end
    value = TS.lookup(doc.data, path)
    kinds = isempty(path) ? (TS.ROOT_TABLE,) :
        value isa AbstractDict ?
            (TS.HEADER_TABLE, TS.IMPLICIT_TABLE, TS.INLINE_TABLE, TS.TABLE_ARRAY_ELEMENT) :
        value isa AbstractVector ? (TS.ARRAY, TS.TABLE_ARRAY) : (TS.SCALAR,)
    kind in kinds || return "kind $kind for $(typeof(value))"

    name = isempty(path) ? nothing : path[end] isa String ? path[end] :
        kind === TS.TABLE_ARRAY_ELEMENT ? path[end-1] : nothing
    if name === nothing
        item.key === nothing || return "unexpected key span"
    else
        item.key === nothing && return "no key span"
        key = span_text(source, item.key)
        isequal(TS.parse_data(key * " = 0"), Dict{String,Any}(name => 0)) ||
            return "key $(repr(key))"
    end

    if kind === TS.ROOT_TABLE
        item.value == TS.Span(1, ncodeunits(source) + 1) || return "root span $(item.value)"
    elseif kind === TS.IMPLICIT_TABLE || kind === TS.TABLE_ARRAY
        item.value === nothing || return "unexpected value span"
    elseif kind === TS.HEADER_TABLE || kind === TS.TABLE_ARRAY_ELEMENT
        item.value === nothing && return "no header span"
        header = span_text(source, item.value)
        open, close = kind === TS.HEADER_TABLE ? ("[", "]") : ("[[", "]]")
        startswith(header, open) && endswith(header, close) &&
            (kind === TS.TABLE_ARRAY_ELEMENT || !startswith(header, "[[")) ||
            return "header $(repr(header))"
        data = TS.parse_data(header)
        data isa Dict && header_keys(data) == filter(c -> c isa String, path) ||
            return "header $(repr(header))"
    else
        item.value === nothing && return "no value span"
        text = span_text(source, item.value)
        data = TS.parse_data("v = " * text)
        data isa Dict && isequal(data["v"], value) || return "value $(repr(text))"
    end

    if kind in (TS.SCALAR, TS.ARRAY, TS.INLINE_TABLE) && path[end] isa String
        item.entry === nothing && return "no entry span"
        (item.entry.past_last == item.value.past_last && item.entry.first ≤ item.key.first) ||
            return "entry span $(item.entry)"
        text = span_text(source, item.entry)
        entry_data = TS.parse_data(text)
        entry_data isa Dict && length(entry_data) == 1 && any(eachindex(path)) do i
            suffix = path[i:end]
            all(c -> c isa String, suffix) && isequal(TS.lookup(entry_data, suffix), value)
        end || return "entry $(repr(text))"
    else
        item.entry === nothing || return "unexpected entry span"
    end
    return nothing
end

function span_problems(doc::TS.Document)
    problems = String[]
    paths = data_paths!(Set{TS.Path}(), TS.Path(), doc.data)
    for path in setdiff(paths, keys(doc.items))
        push!(problems, "no item at $path")
    end
    for (path, item) in doc.items
        if path in paths
            problem = item_problem(doc, path, item)
            problem === nothing || push!(problems, "$path: $problem")
        else
            push!(problems, "item without data at $path")
        end
    end
    return problems
end

describe(@nospecialize(result)) =
    result isa Exception ? sprint(showerror, result) : string(typeof(result))

# What a failure is compared by, since the fork and upstream have distinct `ParserError`s
function failure(@nospecialize(result))
    result isa Union{TS.ParserError,Upstream.ParserError} && return (Symbol(result.type),
        result.data, result.line, result.column, result.pos, result.table, describe(result))
    return result isa Exception ? (typeof(result), describe(result)) : nothing
end

# The fork must parse `source` exactly as the upstream parser does, and record valid spans.
function source_problems(source::String)
    expected = try
        Upstream.tryparse(Upstream.Parser{Dates}(source))
    catch err
        err
    end
    actual = try
        TS.tryparse(source)
    catch err
        err
    end
    # Failures must be the same, including upstream bugs such as an `ArgumentError` thrown
    # for `a = 0x-1`.
    if expected isa Exception
        isequal(failure(actual), failure(expected)) && return String[]
        return ["$(describe(actual)), but upstream: $(describe(expected))"]
    end
    actual isa TS.Document || return ["$(describe(actual)), but upstream parses"]
    isequal(actual.data, expected) || return ["data differs from upstream"]
    return span_problems(actual)
end

function problems_by_source(sources)
    problems = Dict{String,Vector{String}}()
    for (label, source) in sources
        found = try
            source_problems(source)
        catch err
            ["checking threw $(describe(err))"]
        end
        isempty(found) || (problems[label] = found)
    end
    return problems
end

@testset "upstream tests" begin
    Base.include(adapt, UpstreamTests, joinpath(UPSTREAM, "stdlib", "TOML", "test", "runtests.jl"))
end

@testset "agreement with upstream and source locations" begin
    # Including the toml-test suite, parsed by the upstream tests
    @testset "sources from upstream tests" begin
        sources = unique(ForkTOML.sources)
        @test length(sources) > 100
        @test isempty(problems_by_source(sources))
    end

    @testset "local sources" begin
        sources = Pair{String,String}[
            path => read(path, String)
            for path in (joinpath(@__DIR__, "..", "Project.toml"),
                         joinpath(@__DIR__, "Project.toml"))]
        push!(sources, "mixed" => """
            title = "TOML"
            numbers = [1, 0x10, 2.5, -inf, true, 1979-05-27, 07:32:00, 1979-05-27T07:32:00Z]
            nested = [[1, 2], ["a"], [{ x = 1 }]]
            a . "b.c" = { d . e = [true, false] } # comment
            date = 1979-05-27 # comment
            [table.sub]
            inline = { key = "value", "quoted key" = 'literal' }
            [[items]]
            name = "first"
            [[items]]
            name = "second"
            [items.extra]
            [[items.nested]]
            """)
        push!(sources, "empty" => "", "comment only" => "# comment only\n")
        @test isempty(problems_by_source(sources))
    end

    # E.g. `TOMLSOURCE_TEST_CORPUS=~/.julia` checks the TOML files of a depot.
    corpus = get(ENV, "TOMLSOURCE_TEST_CORPUS", "")
    isempty(corpus) || @testset "corpus" begin
        files = String[joinpath(directory, filename)
            for root in split(corpus, Sys.iswindows() ? ';' : ':') if !isempty(root)
            for (directory, _, filenames) in walkdir(expanduser(root); onerror=Returns(nothing))
            for filename in filenames if endswith(filename, ".toml")]
        @test isempty(problems_by_source(file => read(file, String) for file in files))
    end
end

end # module test_upstream
