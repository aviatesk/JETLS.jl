"""
Return a tree where all nodes of `kinds` are removed.  Should not modify any
nodes, and should not create new nodes unnecessarily.
"""
function _without_kinds(st::JL.SyntaxTree, kinds::Tuple)
    if JS.kind(st) in kinds
        return (nothing, true)
    elseif JS.is_leaf(st)
        return (st, false)
    end
    new_children = JL.SyntaxList(JL.syntax_graph(st))
    changed = false
    for c in JS.children(st)
        nc, cc = _without_kinds(c, kinds)
        changed |= cc
        isnothing(nc) || push!(new_children, nc)
    end
    k = JS.kind(st)
    new_node = changed ?
        JL.@ast(JL.syntax_graph(st), st, [k new_children...]) : st
    return (new_node, changed)
end

function without_kinds(st::JL.SyntaxTree, kinds::Tuple)
    return JS.kind(st) in kinds ?
        JL.@ast(JL.syntax_graph(st), st, [JS.K"TOMBSTONE"]) :
        _without_kinds(st, kinds)[1]
end

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

function traverse(@specialize(callback), st::JL.SyntaxTree)
    stack = JL.SyntaxList(st)
    push!(stack, st)
    _traverse!(callback, stack)
end
traverse(@specialize(callback), sn::JL.SyntaxNode) = _traverse!(callback, JS.SyntaxNode[sn])

function _traverse!(@specialize(callback), stack)
    while !isempty(stack)
        x = pop!(stack)
        callback(x)
        if JS.numchildren(x) === 0
            continue
        end
        for i = JS.numchildren(x):-1:1
            push!(stack, x[i])
        end
    end
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
function byte_ancestors(st::JL.SyntaxTree, rng::UnitRange{<:Integer})
    sl = JL.SyntaxList(st)
    if rng ⊆ JS.byte_range(st)
        push!(sl, st)
    else
        # Children of a lowered SyntaxTree don't necessarily fall within their parent's range,
        # so we continue traversing
    end
    traverse(st) do st′
        if rng ⊆ JS.byte_range(st′)
            push!(sl, st′)
        end
    end
    # delete later duplicates when sorted parent->child
    return reverse!(deduplicate_syntaxlist(sl))
end
byte_ancestors(st::JL.SyntaxTree, byte::Integer) = byte_ancestors(st, byte:byte)

function byte_ancestors(sn::JS.SyntaxNode, rng::UnitRange{<:Integer})
    out = JS.SyntaxNode[]
    if rng ⊆ JS.byte_range(sn)
        push!(out, sn)
    else
        return out
    end
    traverse(sn) do sn′
        if rng ⊆ JS.byte_range(sn′)
            push!(out, sn′)
        end
    end
    return reverse!(out)
end
byte_ancestors(sn::JS.SyntaxNode, byte::Integer) = byte_ancestors(sn, byte:byte)

"""
    greatest_local(st0, b) -> (st::Union{SyntaxTree, Nothing}, b::Int)

Return the largest tree that can introduce local bindings that are visible to
the cursor (if any such tree exists), and the cursor's position within it.
"""
function greatest_local(st0::JL.SyntaxTree, b::Int)
    bas = byte_ancestors(st0, b)
    first_global = findfirst(st::JL.SyntaxTree -> JL.kind(st) in JS.KSet"toplevel module", bas)
    isnothing(first_global) && return nothing

    if first_global == 1
        return nothing
    end

    i = first_global - 1
    while JL.kind(bas[i]) === JS.K"block"
        # bas[i] is a block within a global scope, so can't introduce local
        # bindings.  Shrink the tree (mostly for performance).
        i -= 1
        i < 1 && return nothing
    end

    return bas[i], (b - (JS.first_byte(st0) - 1))
end

"""
GreenTreeCursor, but flattened to only include terminal RawGreenNodes.

ParseStream's `.output` is a post-order DFS of the green tree with relative
positions only.  To interpret this as a linear list of tokens in source order,
just ignore any non-terminal node, and accumulate the byte lengths of terminals.
"""
struct TokenCursor
    tokens::Vector{JS.RawGreenNode}
    position::UInt32
    next_byte::UInt32
end
function TokenCursor(ps::JS.ParseStream)
    tokens = filter(tok::JS.RawGreenNode -> !JS.is_non_terminal(tok) && JS.kind(tok) !== JS.K"TOMBSTONE", ps.output)
    next_byte = 1
    if !isempty(tokens)
        next_byte += tokens[1].byte_span
    end
    return TokenCursor(tokens, 1, next_byte)
end

@inline Base.iterate(tc::TokenCursor) = isempty(tc.tokens) ? nothing : (tc, (tc.position, tc.next_byte))
@inline function Base.iterate(tc::TokenCursor, state)
    s_pos, s_byte = state
    s_pos >= lastindex(tc.tokens) && return nothing
    out = (s_pos + 1, s_byte + tc.tokens[s_pos + 1].byte_span)
    return TokenCursor(tc.tokens, out...), out
end
Base.IteratorEltype(::Type{TokenCursor}) = Base.HasEltype()
Base.eltype(::Type{TokenCursor}) = TokenCursor
Base.IteratorSize(::Type{TokenCursor}) = Base.HasLength()
Base.length(tc::TokenCursor) = length(tc.tokens)
next_tok(tc::TokenCursor) =
    @something(Base.iterate(tc, (tc.position, tc.next_byte)), return nothing)[1]
prev_tok(tc::TokenCursor) = tc.position <= 1 ? nothing :
    TokenCursor(tc.tokens, tc.position - 1, tc.next_byte - tc.tokens[tc.position].byte_span)
first_byte(tc::TokenCursor) = tc.position <= 1 ? UInt32(1) : prev_tok(tc).next_byte
last_byte(tc::TokenCursor) = tc.next_byte - UInt32(1)
byte_range(tc::TokenCursor) = first_byte(tc):last_byte(tc)
this(tc::TokenCursor) = tc.tokens[tc.position]

"""
    token_at_offset(fi::FileInfo, offset::Int)

Get the current token index at a given byte offset in a parsed file.

Example:
- `al│pha beta gamma` (`b`=3) returns the index of `alpha`
- `│alpha beta gamma` (`b`=1) returns the index of `alpha`
- `alpha│ beta gamma` (`b`=6) returns the index of ` ` (whitespace)
- `alpha │beta gamma` (`b`=7) returns the index of `beta`
"""
function token_at_offset(ps::JS.ParseStream, offset::Int)
    for tc in TokenCursor(ps)
        start_byte = tc.next_byte - this(tc).byte_span
        if start_byte ≤ offset < tc.next_byte
            return tc
        end
    end
    return nothing
end
token_at_offset(fi::FileInfo, pos::Position) =
    token_at_offset(fi.parsed_stream, xy_to_offset(fi, pos))

"""
Similar to `token_at_offset`, but when you need token `a` from `a| b c`
"""
token_before_offset(ps::JS.ParseStream, offset::Int) = token_at_offset(ps, offset - 1)
token_before_offset(fi::FileInfo, pos::Position) =
    token_before_offset(fi.parsed_stream, xy_to_offset(fi, pos))

"""
    prev_nontrivia_byte(ps::JS.ParseStream, b::Int; pass_newlines::Bool=false, strict::Bool=false)

Return the last byte position of the previous non-trivia token at or before byte `b`.
Returns `nothing` if no non-trivia token is found or if `b` is beyond the input or before position 1.

Trivia includes whitespace and comments. When `pass_newlines=false` (default),
newlines are treated as non-trivia and will stop the search.

When `strict=true`, the token at position `b` is excluded from the search,
ensuring only strictly previous tokens are considered.

# Example
```julia
# Given: "x  # comment\\ny"
#         ^  ^          ^
#         1  4          14

# From position 5 (in comment):
prev_nontrivia_byte(ps, 5)  # returns 1 (from within comment)

# From position 13 (at newline):
prev_nontrivia_byte(ps, 13)                      # returns 13 (newline)
prev_nontrivia_byte(ps, 13; pass_newlines=true)  # returns 1 ('x')

# From position 14 (at 'y'):
prev_nontrivia_byte(ps, 14)               # returns 14 (already at 'y')
prev_nontrivia_byte(ps, 14; strict=true)  # returns 13 (newline, excludes position 14)

# Out of bounds:
prev_nontrivia_byte(ps, 0)   # returns nothing (before input)
prev_nontrivia_byte(ps, 20)  # returns nothing (beyond input)
```
"""
prev_nontrivia_byte(args...; kwargs...) =
    last_byte(@something prev_nontrivia(args...; kwargs...) return nothing)

"""
    prev_nontrivia(ps::JS.ParseStream, b::Int; pass_newlines::Bool=false, strict::Bool=false)

Find the previous non-trivia token at or before byte position `b`.
Returns the `tc::TokenCursor` for that token, or `nothing` if no non-trivia token is found
or if `b` is beyond the input or before position 1.

Trivia includes whitespace and comments. When `pass_newlines=false` (default),
newlines are treated as non-trivia and will stop the search.

When `strict=true`, the token at position `b` is excluded from the search,
ensuring only strictly previous tokens are considered.

# Example
```julia
# Given: "x  # comment\\ny"
#         ^  ^          ^
#         1  4          14

# From position 5 (in comment):
prev_nontrivia(ps, 5)  # returns TokenCursor for 'x'

# From position 13 (at newline):
prev_nontrivia(ps, 13)                      # returns TokenCursor for newline
prev_nontrivia(ps, 13; pass_newlines=true)  # returns TokenCursor for 'x'

# From position 14 (at 'y'):
prev_nontrivia(ps, 14)               # returns TokenCursor for 'y'
prev_nontrivia(ps, 14; strict=true)  # returns TokenCursor for newline (excludes 'y')

# Out of bounds:
prev_nontrivia(ps, 0)   # returns nothing (before input)
prev_nontrivia(ps, 20)  # returns nothing (beyond input)
```
"""
prev_nontrivia(args...; kwargs...) = find_nontrivia(#=prev_or_next=#true, args...; kwargs...)

"""
    next_nontrivia_byte(ps::JS.ParseStream, b::Int; pass_newlines::Bool=false, strict::Bool=false)

Return the first byte position of the next non-trivia token at or after byte `b`.
Returns `nothing` if no non-trivia token is found or if `b` is beyond the input.

Trivia includes whitespace and comments. When `pass_newlines=false` (default),
newlines are treated as non-trivia and will stop the search.

When `strict=true`, the token at position `b` is excluded from the search,
ensuring only strictly next tokens are considered.

# Example
```julia
# Given: "x # comment\\ny #= block =# z"
#         ^ ^          ^ ^           ^
#         1 3         13 15          27

# From position 1 (at 'x'):
next_nontrivia_byte(ps, 1)               # returns 1 (already at 'x')
next_nontrivia_byte(ps, 1; strict=true)  # returns 13 (newline, excludes 'x')

# From position 3 (in comment):
next_nontrivia_byte(ps, 3)                      # returns 13 (stops at newline)
next_nontrivia_byte(ps, 3; pass_newlines=true)  # returns 14 (skip to 'y')

# From position 15 (in block comment):
next_nontrivia_byte(ps, 15)  # returns 27 (comments are trivia)

# Out of bounds:
next_nontrivia_byte(ps, 0)   # returns nothing
next_nontrivia_byte(ps, 40)  # returns nothing
```
"""
next_nontrivia_byte(args...; kwargs...) =
    first_byte(@something next_nontrivia(args...; kwargs...) return nothing)

"""
    next_nontrivia(ps::JS.ParseStream, b::Int; pass_newlines=false, strict=false)

Find the next non-trivia token at or after byte position `b`.
Returns the `tc::TokenCursor` for that token, or `nothing` if no non-trivia token is found
or if `b` is beyond the input.

Trivia includes whitespace and comments. When `pass_newlines=false` (default),
newlines are treated as non-trivia and will stop the search.

When `strict=true`, the token at position `b` is excluded from the search,
ensuring only strictly next tokens are considered.

# Example
```julia
# Given: "x # comment\\ny #= block =# z"
#         ^ ^          ^ ^           ^
#         1 3         13 15          27

# From position 1 (at 'x'):
next_nontrivia(ps, 1)               # returns TokenCursor for 'x'
next_nontrivia(ps, 1; strict=true)  # returns TokenCursor for newline (excludes 'x')

# From position 3 (in comment):
next_nontrivia(ps, 3)                      # returns TokenCursor for newline (stops at newline)
next_nontrivia(ps, 3; pass_newlines=true)  # returns TokenCursor for 'y'

# From position 15 (in block comment):
next_nontrivia(ps, 15)  # returns TokenCursor for 'z' (comments are trivia)

# Out of bounds:
next_nontrivia(ps, 0)   # returns nothing
next_nontrivia(ps, 40)  # returns nothing
```
"""
next_nontrivia(args...; kwargs...) = find_nontrivia(#=prev_or_next=#false, args...; kwargs...)

function find_nontrivia(prev_or_next::Bool, ps::JS.ParseStream, b::Int; pass_newlines::Bool=false, strict::Bool=false)
    tc = @something token_at_offset(ps, b) return nothing
    if !strict && !is_trivia(tc, pass_newlines)
        return tc
    end
    while true
        tc = @something (prev_or_next ? prev_tok(tc) : next_tok(tc)) return nothing
        is_trivia(tc, pass_newlines) && continue
        return tc
    end
end

function is_trivia(tc::TokenCursor, pass_newlines::Bool)
    k = kind(this(tc))
    JS.is_whitespace(k) && (pass_newlines || k !== JS.K"NewlineWs")
end

noparen_macrocall(st0::JL.SyntaxTree) =
    JS.kind(st0) === JS.K"macrocall" &&
    !(JS.numchildren(st0) ≥ 2 && JS.kind(st0[1]) === JS.K"StringMacroName") &&
    !JS.has_flags(st0, JS.PARENS_FLAG)

"""
    select_target_node(st0::JL.SyntaxTree, offset::Int) -> target::Union{JL.SyntaxTree,Nothing}

Determines the node that the user most likely intends to navigate to.
Returns `nothing` if no suitable one is found.
Currently `st0` needs to be a `SyntaxTree` before lowering.

Currently, it simply checks the ancestors of the node located at the given offset.

TODO: Apply a heuristic similar to rust-analyzer
refs:
- https://github.com/rust-lang/rust-analyzer/blob/6acff6c1f8306a0a1d29be8fd1ffa63cff1ad598/crates/ide/src/goto_definition.rs#L47-L62
- https://github.com/aviatesk/JETLS.jl/pull/61#discussion_r2134707773
"""
function select_target_node(node0::Union{JS.SyntaxNode,JL.SyntaxTree}, offset::Int)
    bas = byte_ancestors(node0, offset)

    isempty(bas) && @goto minus1
    target = first(bas)
    if !JS.is_identifier(target)
        @label minus1
        offset > 0 || return nothing
        # Support cases like `var│`, `func│(5)`
        bas = byte_ancestors(node0, offset - 1)
        isempty(bas) && return nothing
        target = first(bas)
        if !JS.is_identifier(target)
            return nothing
        end
    end

    for i = 2:length(bas)
        basᵢ = bas[i]
        if (JS.kind(basᵢ) === JS.K"." &&
            basᵢ[1] !== target) # e.g. don't allow jumps to `tmeet` from `Base.Compi│ler.tmeet`
            target = basᵢ
        else
            return target
        end
    end

    # Unreachable: we always have toplevel node
    return nothing
end

"""
    select_dotprefix_node(st::JL.SyntaxTree, offset::Int) -> dotprefix::Union{JL.SyntaxTree,Nothing}

If the code at `offset` position is dot accessor code, get the code being dot accessed.
For example, `Base.show_│` returns the `SyntaxTree` of `Base`.
If it's not dot accessor code, return `nothing`.
"""
function select_dotprefix_node(st::JL.SyntaxTree, offset::Int)
    bas = byte_ancestors(st, offset-1)
    dotprefix = nothing
    for i = 1:length(bas)
        basᵢ = bas[i]
        if JS.kind(basᵢ) === JS.K"."
            dotprefix = basᵢ
        elseif dotprefix !== nothing
            break
        end
    end
    if dotprefix !== nothing && JS.numchildren(dotprefix) ≥ 2
        return dotprefix[1]
    end
    return nothing
end

"""
    jsobj_to_range(
            obj, fi::FileInfo;
            include_at_mark::Union{Nothing,Bool} = nothing,
            adjust_first::Int = 0, adjust_last::Int = 0
        ) -> range::LSP.Range

Returns the position information of a JuliaSyntax object in the source file in `LSP.Range` format.

# Arguments
- `obj`: A JuliaSyntax object with byte range information (typically a `SyntaxNode` or `SyntaxTree`,
  must respond to `JS.first_byte`, `JS.last_byte`, and `JS.kind`)
- `fi::FileInfo`: The file info containing the parsed content

# Keyword Arguments
- `include_at_mark::Union{Nothing,Bool} = nothing`: Whether to include the `@` character for macro names.
  When `nothing` (default), automatically set to `true` for `SyntaxNode` or `SyntaxTree` objects,
  `false` otherwise
- `adjust_first::Int = 0`: Adjustment to apply to the first byte position
- `adjust_last::Int = 0`: Adjustment to apply to the last byte position

# Returns
`LSP.Range`: The position range of the object in the source file, with character positions
calculated according to the specified encoding.

# Details
The function converts byte offsets from JuliaSyntax to LSP-compatible positions using
the specified encoding. For macro names, it can optionally adjust the start position
to include the `@` character.

Note that `+1` is added to `JS.last_byte(obj)` when calculating the end position
(additionally, if `adjust_last` is specified, that value is also added).
`JS.last_byte(obj)` returns the 1-based byte index of the last byte that belongs to
the object. To create a range that includes this byte, we need the position after it,
since LSP uses half-open intervals [start, end) where the end position is exclusive.
This follows the standard convention where the end position points to the first
character/byte that is NOT part of the range.
"""
function jsobj_to_range(
        obj, fi::FileInfo;
        include_at_mark::Union{Nothing,Bool} = nothing,
        adjust_first::Int = 0, adjust_last::Int = 0
    )
    fb = JS.first_byte(obj)
    lb = JS.last_byte(obj)
    if iszero(fb)
        line, _ = JS.source_location(obj)
        rng = line_range(line)
        if iszero(lb)
            return rng
        else
            return Range(rng; var"end" = offset_to_xy(fi, lb+1+adjust_last))
        end
    else
        spos = offset_to_xy(fi, fb+adjust_first)
        if isnothing(include_at_mark)
            include_at_mark = obj isa JS.SyntaxNode || obj isa JL.SyntaxTree
        end
        if include_at_mark && JS.kind(obj) === JS.K"MacroName"
            spos = Position(spos; character = spos.character-1)
        end
        if iszero(lb)
            epos = Position(; line=spos.line, character=Int(typemax(Int32)))
        else
            epos = offset_to_xy(fi, lb+1+adjust_last)
        end
        return Range(; start = spos, var"end" = epos)
    end
end
