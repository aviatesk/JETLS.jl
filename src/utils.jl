function getobjpath(obj, path::Symbol, paths::Symbol...)
    nextobj = getfield(obj, path)
    if nextobj === nothing
        return nothing
    end
    getobjpath(nextobj, paths...)
end
getobjpath(obj) = obj

# path/URI utilities
# ==================

to_full_path(file::Symbol) = to_full_path(String(file))
function to_full_path(file::AbstractString)
    file = Base.fixup_stdlib_path(file)
    file = something(Base.find_source_file(file), file)
    return abspath(file)
end

"""
    create_source_location_link(filepath::AbstractString; line=nothing, character=nothing)

Create a markdown-style link to a source location that can be displayed in LSP clients.

This function generates links in the format `"[show text](file://path#L#C)"` which, while
not explicitly stated in the LSP specification, is supported by most LSP clients for
navigation to specific file locations.

# Arguments
- `filepath::AbstractString`: The file path to link to
- `line::Union{Integer,Nothing}=nothing`: Optional 1-based line number
- `character::Union{Integer,Nothing}=nothing`: Optional character position (requires `line` to be specified)

# Returns
A markdown-formatted string containing the clickable link.

# Examples
```julia
create_source_location_link("/path/to/file.jl")
# Returns: "[/path/to/file.jl](file:///path/to/file.jl)"

create_source_location_link("/path/to/file.jl", line=42)
# Returns: "[/path/to/file.jl:42](file:///path/to/file.jl#L42)"

create_source_location_link("/path/to/file.jl", line=42, character=10)
# Returns: "[/path/to/file.jl:42](file:///path/to/file.jl#L42C10)"
```
"""
function create_source_location_link(filepath::AbstractString;
                                     line::Union{Integer,Nothing}=nothing,
                                     character::Union{Integer,Nothing}=nothing)
    linktext = string(filepath2uri(filepath))
    showtext = filepath
    Base.stacktrace_contract_userdir() && (showtext = Base.contractuser(showtext))
    if line !== nothing
        linktext *= "#L$line"
        showtext *= string(":", line)
        if character !== nothing
            linktext *= "C$character"
        end
    end
    return "[$showtext]($linktext)"
end

# TODO Need to make them thread safe when making the message handling multithreaded

let debounced = Dict{UInt,Timer}()
    global function debounce(f, id::UInt, delay)
        if haskey(debounced, id)
            close(debounced[id])
        end
        debounced[id] = Timer(delay) do _
            try
                f()
            finally
                delete!(debounced, id)
            end
        end
        nothing
    end
end

let throttled = Dict{UInt, Tuple{Union{Nothing,Timer}, Float64}}()
    global function throttle(f, id::UInt, interval)
        if !haskey(throttled, id)
            f()
            throttled[id] = (nothing, time())
            return nothing
        end
        last_timer, last_time = throttled[id]
        if last_timer !== nothing
            close(last_timer)
        end
        delay = max(0.0, interval - (time() - last_time))
        throttled[id] = (Timer(delay) do _
            try
                f()
            finally
                throttled[id] = (nothing, time())
            end
        end, last_time)
        nothing
    end
end

"""
Fetch cached FileInfo given an LSclient-provided structure with a URI
"""
get_fileinfo(s::ServerState, uri::URI) = haskey(s.file_cache, uri) ? s.file_cache[uri] : nothing
get_fileinfo(s::ServerState, t::TextDocumentIdentifier) = get_fileinfo(s, t.uri)

function find_file_module!(state::ServerState, uri::URI, pos::Position)
    mod = find_file_module(state, uri, pos)
    state.completion_module = mod
    return mod
end
function find_file_module(state::ServerState, uri::URI, pos::Position)
    context = find_context_for_uri(state, uri)
    context === nothing && return Main
    safi = successfully_analyzed_file_info(context, uri)
    isnothing(safi) && return Main
    curline = Int(pos.line) + 1
    curmod = Main
    for (range, mod) in safi.module_range_infos
        curline in range || continue
        curmod = mod
    end
    return curmod
end

function find_context_for_uri(state::ServerState, uri::URI)
    haskey(state.contexts, uri) || return nothing
    contexts = state.contexts[uri]
    contexts isa ExternalContext && return nothing
    context = first(contexts)
    for ctx in contexts
        # prioritize `PackageSourceAnalysisEntry` if exists
        if isa(context.entry, PackageSourceAnalysisEntry)
            context = ctx
            break
        end
    end
    return context
end

# JuliaLowering uses byte offsets; LSP uses lineno and UTF-* character offset.
# These functions do the conversion.

"""
    xy_to_offset(code::Vector{UInt8}, pos::Position)
    xy_to_offset(fi::FileInfo, pos::Position)

Convert 0-based `pos::Position` (equivalent to `(; line = y, character = x)`) to a 1-based byte offset.
Basically, `pos` is expected to be valid with respect to `code`.
However, some language server clients sometimes send invalid `Position`s,
so this function is designed not to error on such invalid `Position`s.
Note that the byte offset returned in such cases has almost no meaning.
"""
function xy_to_offset(code::Vector{UInt8}, pos::Position)
    b = 0
    for z in 1:pos.line
        nextb = findnext(isequal(UInt8('\n')), code, b + 1)
        if isnothing(nextb) # guard against invalid `pos`
            break
        end
        b = nextb
    end
    lend = findnext(isequal(UInt8('\n')), code, b + 1)
    lend = isnothing(lend) ? lastindex(code) + 1 : lend
    curline = String(code[b+1:lend-1]) # current line, containing no newlines
    line_b = 1
    for i in 1:pos.character
        checkbounds(Bool, curline, line_b) || break # guard against invalid `pos`
        line_b = nextind(curline, line_b)
    end
    return b + line_b
end
xy_to_offset(fi::FileInfo, pos::Position) = xy_to_offset(fi.parsed_stream.textbuf, pos)

"""
    offset_to_xy(ps::JS.ParseStream, byte::Int)
    offset_to_xy(fi::FileInfo, byte::Int)

Convert a 1-based byte offset to a 0-based line and character number
"""
function offset_to_xy(ps::JS.ParseStream, byte::Int)
    # ps must be parsed already
    @assert byte in JS.first_byte(ps):JS.last_byte(ps) + 1
    sf = JS.SourceFile(ps)
    l, c = JuliaSyntax.source_location(sf, byte)
    return Position(;line = l-1, character = c-1)
end
function offset_to_xy(code::Union{AbstractString, Vector{UInt8}}, byte::Int) # used by tests
    ps = JS.parse!(JS.ParseStream(code), rule=:all)
    return offset_to_xy(ps, byte)
end
offset_to_xy(fi::FileInfo, byte::Int) = offset_to_xy(fi.parsed_stream, byte)

"""
Like `Base.unique`, but over node ids, and with this comment promising that the
lowest-index copy of each node is kept.
"""
function deduplicate_syntaxlist(sl::JL.SyntaxList)
    sl2 = JL.SyntaxList(sl.graph)
    seen = Set{JL.NodeId}()
    for st in sl
        if !(st._id in seen)
            push!(sl2, st._id)
            push!(seen, st._id)
        end
    end
    return sl2
end

"""
    byte_ancestors(st::JL.SyntaxTree, rng::UnitRange{Int})
    byte_ancestors(st::JL.SyntaxTree, byte::Int)

Get a SyntaxList of `SyntaxTree`s containing certain bytes.

    byte_ancestors(sn::JS.SyntaxNode, rng::UnitRange{Int})
    byte_ancestors(sn::JS.SyntaxNode, byte::Int)

Get a list of `SyntaxNode`s containing certain bytes.

Output should be topologically sorted, children first.  If we know that parent
ranges contain all child ranges, and that siblings don't have overlapping ranges
(this is not true after lowering, but appears to be true after parsing), each
tree in the result will be a child of the next.
"""
function byte_ancestors(st::JL.SyntaxTree, rng::UnitRange{Int})
    sl = JL.SyntaxList(st._graph, [st._id])
    stack = [st]
    while !isempty(stack)
        st = pop!(stack)
        if JS.numchildren(st) === 0
            continue
        end
        for ci in JS.children(st)
            if rng ⊆ JS.byte_range(ci)
                push!(sl, ci)
            end
            push!(stack, ci)
        end
    end
    # delete later duplicates when sorted parent->child
    return reverse!(deduplicate_syntaxlist(sl))
end
byte_ancestors(st::JL.SyntaxTree, byte::Int) = byte_ancestors(st, byte:byte)

function byte_ancestors(sn::JS.SyntaxNode, rng::UnitRange{Int})
    out = JS.SyntaxNode[]
    stack = JS.SyntaxNode[sn]
    while !isempty(stack)
        cursn = pop!(stack)
        (JS.numchildren(cursn) === 0) && continue
        for i = JS.numchildren(cursn):-1:1
            childsn = cursn[i]
            push!(stack, childsn)
            if rng ⊆ JS.byte_range(childsn)
                push!(out, childsn)
            end
        end
    end
    return reverse!(out)
end
byte_ancestors(sn::JS.SyntaxNode, byte::Int) = byte_ancestors(sn, byte:byte)

"""
Resolve a name's value given a root module and an expression like `M1.M2.M3.f`,
which parses to `(. (. (. M1 M2) M3) f)`.  If we hit something undefined, return
nothing.  This doesn't support some cases, e.g. `(print("hi"); Base).print`
"""
function resolve_property(mod::Module, st0::JL.SyntaxTree)
    if JS.is_leaf(st0)
        # Would otherwise throw an unhelpful error.  Is this true of all leaf nodes?
        @assert JL.hasattr(st0, :name_val)
        s = Symbol(st0.name_val)
        !(@invokelatest isdefinedglobal(mod, s)) && return nothing
        return @invokelatest getglobal(mod, s)
    elseif kind(st0) === K"."
        @assert JS.numchildren(st0) === 2
        lhs = resolve_property(mod, st0[1])
        return resolve_property(lhs, st0[2])
    end
    JETLS_DEV_MODE && @info "resolve_property couldn't handle form:" mod st0
    return nothing
end
