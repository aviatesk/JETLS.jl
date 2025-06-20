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
function offset_to_xy(ps::JS.ParseStream, byte::Integer)
    # ps must be parsed already
    @assert byte in JS.first_byte(ps):JS.last_byte(ps) + 1 "Byte offset is out of bounds for the parse stream"
    sf = JS.SourceFile(ps)
    l, c = JuliaSyntax.source_location(sf, byte)
    return Position(;line = l-1, character = c-1)
end
function offset_to_xy(code::Union{AbstractString, Vector{UInt8}}, byte::Int) # used by tests
    ps = JS.parse!(JS.ParseStream(code), rule=:all)
    return offset_to_xy(ps, byte)
end
offset_to_xy(fi::FileInfo, byte::Integer) = offset_to_xy(fi.parsed_stream, byte)

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

# TODO: Refactor for JuliaLang/JuliaSyntax.jl#560
"""
    get_current_token_idx(fi::FileInfo, offset::Int)

Get the current token index at a given byte offset in a parsed file.
This function returns the token at the specified byte offset, or `nothing`
if the offset is invalid or no token exists at that position.

Example:
al│pha beta gamma      (b=3) returns the index of `alpha`
│alpha beta gamma      (b=1) returns the index of `alpha`
alpha│ beta gamma      (b=6) returns the index of ` ` (whitespace)
alpha │beta gamma      (b=7) returns the index of `beta`
"""
function get_current_token_idx(ps::JS.ParseStream, offset::Int)
    offset < 1 && return nothing
    findfirst(token -> token.next_byte > offset, ps.tokens)
end

function get_current_token_idx(fi::FileInfo, pos::Position)
    fi === nothing && return nothing
    get_current_token_idx(fi.parsed_stream, xy_to_offset(fi, pos))
end

"""
Similar to `get_current_token_idx`, but when you need token `a` from `a| b c`
"""
function get_prev_token_idx(ps::JS.ParseStream, offset::Int)
    get_current_token_idx(ps, offset - 1)
end
function get_prev_token_idx(fi::FileInfo, pos::Position)
    fi === nothing && return nothing
    get_prev_token_idx(fi.parsed_stream, xy_to_offset(fi, pos))
end

function noparen_macrocall(st0::JL.SyntaxTree)
    JS.kind(st0) === JS.K"macrocall" && !JS.has_flags(st0, JS.PARENS_FLAG)
end
