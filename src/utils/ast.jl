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
    for _ in 1:pos.line
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
    for _ in 1:pos.character
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
offset_to_xy(code::Union{AbstractString, Vector{UInt8}}, byte::Integer) = # used by tests
    offset_to_xy(JS.parse!(JS.ParseStream(code), rule=:all), byte)
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

# HACK: Replace macrocalls (except @nospecialize) with block expressions containing
# their arguments as they are. This preserves local binding information for better
# completion and definition features, though it's not a complete fix.
# Once a full macro expansion support in JuliaLowering is landed,
# this function can just removed.
function remove_macrocalls(st0::JL.SyntaxTree)
    ctx = JL.MacroExpansionContext(JL.syntax_graph(st0), JL.Bindings(),
                                   JL.ScopeLayer[], JL.ScopeLayer(1, Module(), false))
    if JS.kind(st0) === JS.K"macrocall"
        macroname = st0[1]
        if hasproperty(macroname, :name_val) && macroname.name_val == "@nospecialize"
            st0
        else
            JL.@ast ctx st0 [JS.K"block" (map(remove_macrocalls, JS.children(st0)))...]
        end
    elseif JS.is_leaf(st0)
        st0
    else
        k = JS.kind(st0)
        JL.@ast ctx st0 [k (map(remove_macrocalls, JS.children(st0)))...]
    end
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
    prev_nontrivia_byte(ps::JS.ParseStream, b::Int; pass_newlines::Bool=false)

Return the last byte position of the previous non-trivia token at or before byte `b`.
Returns `nothing` if no non-trivia token is found or if `b` is beyond the input or before position 1.

Trivia includes whitespace and comments. When `pass_newlines=false` (default),
newlines are treated as non-trivia and will stop the search.

# Example
```julia
# Given: "x  # comment\\ny"
#         ^  ^         ^
#         1  4        14
prev_nontrivia_byte(ps, 14)  # returns 14 (already at 'y')
prev_nontrivia_byte(ps, 13)  # returns 13 (newline)
prev_nontrivia_byte(ps, 13; pass_newlines=true)  # returns 1 ('x')
prev_nontrivia_byte(ps, 5)  # returns 1 (from within comment)
prev_nontrivia_byte(ps, 0)  # returns nothing (before input)
prev_nontrivia_byte(ps, 20)  # returns nothing (beyond input)
```
"""
function prev_nontrivia_byte(ps::JS.ParseStream, b::Int; pass_newlines::Bool=false)
    last_byte(@something prev_nontrivia(ps, b; pass_newlines) return nothing)
end

"""
    prev_nontrivia(ps::JS.ParseStream, b::Int; pass_newlines::Bool=false)

Find the previous non-trivia token at or before byte position `b`.
Returns the `tc::TokenCursor` for that token, or `nothing` if no non-trivia token is found
or if `b` is beyond the input or before position 1.

Trivia includes whitespace and comments. When `pass_newlines=false` (default),
newlines are treated as non-trivia and will stop the search.

# Example
```julia
# Given: "x  # comment\\ny"
#         ^  ^          ^
#         1  4          14

# From position 14 (at 'y'):
prev_nontrivia(ps, 14)  # returns TokenCursor for 'y'

# From position 13 (at newline):
prev_nontrivia(ps, 13)  # returns TokenCursor for newline
prev_nontrivia(ps, 13; pass_newlines=true)  # returns TokenCursor for 'x'

# From position 5 (in comment):
prev_nontrivia(ps, 5)  # returns TokenCursor for 'x'

# Out of bounds:
prev_nontrivia(ps, 0)   # returns nothing (before input)
prev_nontrivia(ps, 20)  # returns nothing (beyond input)
```
"""
function prev_nontrivia(ps::JS.ParseStream, b::Int; pass_newlines::Bool=false)
    tc = @something token_at_offset(ps, b) return nothing
    if !is_trivia(tc, pass_newlines)
        return tc
    end
    while true
        tc = @something prev_tok(tc) return nothing
        if !is_trivia(tc, pass_newlines)
            return tc
        end
    end
end

"""
    next_nontrivia_byte(ps::JS.ParseStream, b::Int; pass_newlines::Bool=false)

Return the first byte position of the next non-trivia token at or after byte `b`.
Returns `nothing` if no non-trivia token is found or if `b` is beyond the input.

Trivia includes whitespace and comments. When `pass_newlines=false` (default),
newlines are treated as non-trivia and will stop the search.

# Example
```julia
# Given: "x  # comment\\ny"
#         ^  ^          ^
#         1  4          14
next_nontrivia_byte(ps, 1)  # returns 1 (already at 'x')
next_nontrivia_byte(ps, 2)  # returns 13 (newline - comment is trivia)
next_nontrivia_byte(ps, 4)  # returns 13 (from within comment)
next_nontrivia_byte(ps, 4; pass_newlines=true)  # returns 14 (skip to 'y')
next_nontrivia_byte(ps, 15)  # returns nothing (beyond input)
```
"""
next_nontrivia_byte(ps::JS.ParseStream, b::Int; pass_newlines::Bool=false) =
    first_byte(@something next_nontrivia(ps, b; pass_newlines) return nothing)

"""
    next_nontrivia(ps::JS.ParseStream, b::Int; pass_newlines=false)

Find the next non-trivia token at or after byte position `b`.
Returns the `tc::TokenCursor` for that token, or `nothing` if no non-trivia token is found
or if `b` is beyond the input.

Trivia includes whitespace and comments. When `pass_newlines=false` (default),
newlines are treated as non-trivia and will stop the search.

# Example
```julia
# Given: "x # comment\\ny #= block =# z"
#         ^ ^          ^ ^           ^
#         1 3         13 15          27

# From position 1 (at 'x'):
next_nontrivia(ps, 1)  # returns TokenCursor for 'x'

# From position 3 (in comment):
next_nontrivia(ps, 3)  # returns TokenCursor for newline (stops at newline)
next_nontrivia(ps, 3; pass_newlines=true)  # returns TokenCursor for 'y'

# From position 15 (in block comment):
next_nontrivia(ps, 15)  # returns TokenCursor for 'z' (comments are trivia)

# Out of bounds:
next_nontrivia(ps, 0)  # returns nothing
next_nontrivia(ps, 40)  # returns nothing
```
"""
function next_nontrivia(ps::JS.ParseStream, b::Int; pass_newlines::Bool=false)
    tc = @something token_at_offset(ps, b) return nothing
    while is_trivia(tc, pass_newlines)
        tc = next_tok(tc)
        isnothing(tc) && return nothing
    end
    return tc
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
    get_source_range(node::Union{JS.SyntaxNode,JL.SyntaxTree};
                     include_at_mark::Bool = true,
                     adjust_first::Int = 0, adjust_last::Int = 0) -> range::LSP.Range

Returns the position information of `node` in the source file in `LSP.Range` format.
"""
function get_source_range(node::Union{JS.SyntaxNode,JL.SyntaxTree};
                          include_at_mark::Bool = true,
                          adjust_first::Int = 0, adjust_last::Int = 0)
    sourcefile = JS.sourcefile(node)
    first_line, first_char = JS.source_location(sourcefile, JS.first_byte(node)+adjust_first)
    last_line, last_char = JS.source_location(sourcefile, JS.last_byte(node)+adjust_last)
    return Range(;
        start = Position(;
            line = first_line - 1,
            character = first_char - 1 - (include_at_mark && JS.kind(node) === JS.K"MacroName")),
        var"end" = Position(;
            line = last_line - 1,
            character = last_char))
end
