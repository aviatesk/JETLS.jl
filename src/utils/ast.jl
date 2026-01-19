function build_syntax_tree(fi::FileInfo)
    return JS.build_tree(JS.SyntaxTree, fi.parsed_stream; filename = fi.filename)
end

"""
Return a tree where all nodes of `kinds` are removed.  Should not modify any
nodes, and should not create new nodes unnecessarily.
"""
function _without_kinds(st::JS.SyntaxTree, kinds::Tuple{Vararg{JS.Kind}})
    if JS.kind(st) in kinds
        return (nothing, true)
    elseif JS.is_leaf(st)
        return (st, false)
    end
    new_children = JS.SyntaxList(JS.syntax_graph(st))
    changed = false
    for c in JS.children(st)
        nc, cc = _without_kinds(c, kinds)
        changed |= cc
        isnothing(nc) || push!(new_children, nc)
    end
    k = JS.kind(st)
    new_node = changed ?
        JL.@ast(JS.syntax_graph(st), st, [k new_children...]) : st
    return (new_node, changed)
end

function without_kinds(st::JS.SyntaxTree, kinds::Tuple{Vararg{JS.Kind}})
    return (JS.kind(st) in kinds ?
        JL.@ast(JS.syntax_graph(st), st, [JS.K"TOMBSTONE"]) :
        _without_kinds(st, kinds)[1])::JS.SyntaxTree
end

function is_macrocall_st0(st0::JS.SyntaxTree, names::AbstractString...)
    JS.kind(st0) === JS.K"macrocall" || return false
    JS.numchildren(st0) >= 1 || return false
    macro_name = st0[1]
    JS.kind(macro_name) === JS.K"Identifier" || return false
    hasproperty(macro_name, :name_val) || return false
    return macro_name.name_val in names
end

is_nospecialize_or_specialize_macrocall0(st0::JS.SyntaxTree) =
    is_macrocall_st0(st0, "@nospecialize", "@specialize")

is_mainfunc0(st0::JS.SyntaxTree) = is_macrocall_st0(st0, "@main")

function is_nospecialize_or_specialize_macrocall3(st3::JS.SyntaxTree)
    JS.kind(st3) === JS.K"macrocall" || return false
    JS.numchildren(st3) >= 1 || return false
    macro_name = st3[1]
    JS.kind(macro_name) === JS.K"macro_name" || return false
    JS.numchildren(st3) >= 2 || return false
    macro_name = macro_name[2]
    JS.kind(macro_name) === JS.K"Identifier" || return false
    hasproperty(macro_name, :name_val) || return false
    return macro_name.name_val == "nospecialize" || macro_name.name_val == "specialize"
end

function _remove_macrocalls(st::JS.SyntaxTree)
    if JS.kind(st) === JS.K"macrocall"
        if is_nospecialize_or_specialize_macrocall0(st)
            # Special case `@nospecialize`/`@specialize`:
            # These macros are sometimes used in method definition argument lists, but
            # if we apply the `_remove_macrocalls` transformation directly, it would
            # result in a `:block` expression being inserted into the argument list,
            # preventing generation of a correct lowered tree.
            # Furthermore, JuliaLowering.jl provides new macro style definitions for
            # these macros, so there's no need to remove them in the first place.
            return st, false
        elseif is_mainfunc0(st)
            # `@main` functions are always lowered to `main` functions without issues,
            # so there's no need to remove them
            return st, false
        end
        new_children = JS.SyntaxList(JS.syntax_graph(st))
        for i = 2:JS.numchildren(st)
            push!(new_children, _remove_macrocalls(st[i])[1])
        end
        return JL.@ast(JS.syntax_graph(st), st, [JS.K"block" new_children...]), true
    elseif JS.is_leaf(st)
        return st, false
    end
    new_children = JS.SyntaxList(JS.syntax_graph(st))
    changed = false
    for c in JS.children(st)
        nc, cc = _remove_macrocalls(c)
        changed |= cc
        push!(new_children, nc)
    end
    k = JS.kind(st)
    new_node = changed ?
        JL.@ast(JS.syntax_graph(st), st, [k new_children...]) : st
    return (new_node, changed)
end

"""
    remove_macrocalls(st0::JS.SyntaxTree) -> JS.SyntaxTree

Convert `macrocall` nodes to `block` nodes while preserving binding provenance information
in the arguments passed to macrocalls.

This transformation converts `macrocall children...` to `block children...`, preserving
the binding provenance information contained within expressions passed as arguments to
macrocalls. As a result, LSP features that rely on binding source information (primarily
using surface AST level information) can work in many cases based on binding resolution
performed on the transformed tree `st0′`.

This is useful because JuliaLowering's macro expansion (for old-style macros) loses
fine-grained provenance information, reducing it to line-level granularity. For example,
in `@noop foo`, highlighting `foo` would incorrectly highlight `@noop foo` entirely
if macro expansion were performed. By removing macrocalls before lowering, we
preserve precise source locations for bindings outside of macrocalls.

Note that bindings inside macrocalls will not be analyzed, but this trade-off might be
preferable to having incorrect source ranges. This is especially true for LSP features
like document-highlight and find-references where source-level information is critical,
as information inside macros is often not needed for these features.
"""
remove_macrocalls(st0::JS.SyntaxTree) = first(_remove_macrocalls(st0))

function unwrap_where(node::JS.SyntaxTree)
    while JS.kind(node) === JS.K"where" && JS.numchildren(node) ≥ 1
        node = node[1]
    end
    return node
end

extract_name_val(node::JS.SyntaxTree) =
    hasproperty(node, :name_val) ? node.name_val::String : nothing

"""
Like `Base.unique`, but over node ids, and with this comment promising that the
lowest-index copy of each node is kept.
"""
function deduplicate_syntaxlist(sl::JS.SyntaxList)
    sl2 = JS.SyntaxList(sl.graph)
    seen = Set{JS.NodeId}()
    for st in sl
        if !(st._id in seen)
            push!(sl2, st._id)
            push!(seen, st._id)
        end
    end
    return sl2
end

function traverse(@specialize(callback), st::JS.SyntaxTree)
    stack = JS.SyntaxList(st)
    push!(stack, st)
    _traverse!(callback, stack)
end

struct TraversalReturn{T}
    val::T
    terminate::Bool
    TraversalReturn(val::T; terminate::Bool=false) where T = new{T}(val, terminate)
end
struct TraversalTerminator end
struct TraversalNoRecurse end
function _traverse!(@specialize(callback), stack::JS.SyntaxList)
    local retval = nothing
    while !isempty(stack)
        x = pop!(stack)
        ret = callback(x)
        if ret isa TraversalReturn
            retval = ret.val
            ret.terminate ? break : continue
        end
        ret === TraversalTerminator() && break
        ret === TraversalNoRecurse() && continue
        if JS.numchildren(x) === 0
            continue
        end
        for i = JS.numchildren(x):-1:1
            push!(stack, x[i])
        end
    end
    return retval
end

"""
    byte_ancestors([flt,] st::JS.SyntaxTree, rng::UnitRange{Int})
    byte_ancestors([flt,] st::JS.SyntaxTree, byte::Int)

Get a SyntaxList of `SyntaxTree`s containing certain bytes.

Output should be topologically sorted, children first.  If we know that parent
ranges contain all child ranges, and that siblings don't have overlapping ranges
(this is not true after lowering, but appears to be true after parsing), each
tree in the result will be a child of the next.

An optional filter function `flt` can be provided to include only nodes
that satisfy the predicate.
"""
byte_ancestors(args...) = byte_ancestors(Returns(true), args...)

function byte_ancestors(flt, st::JS.SyntaxTree, rng::UnitRange{<:Integer})
    sl = JS.SyntaxList(st)
    if rng ⊆ JS.byte_range(st) && flt(st)
        push!(sl, st)
    else
        # Children of a lowered SyntaxTree don't necessarily fall within their parent's range,
        # so we continue traversing
    end
    traverse(st) do st′
        if rng ⊆ JS.byte_range(st′) && flt(st′)
            push!(sl, st′)
        end
    end
    # delete later duplicates when sorted parent->child
    return reverse!(deduplicate_syntaxlist(sl))
end
byte_ancestors(flt, st::JS.SyntaxTree, byte::Integer) = byte_ancestors(flt, st, byte:byte)

"""
    greatest_local(st0::JS.SyntaxTree, offset::Int) -> st::Union{JS.SyntaxTree, Nothing}

Return the largest tree that can introduce local bindings that are visible to the cursor
(if any such tree exists).
"""
function greatest_local(st0::JS.SyntaxTree, offset::Int)
    bas = byte_ancestors(st0, offset)
    first_global = findfirst(st::JS.SyntaxTree -> JS.kind(st) in JS.KSet"toplevel module", bas)
    isnothing(first_global) && return nothing

    if first_global == 1
        return nothing
    end

    i = first_global - 1
    while JS.kind(bas[i]) === JS.K"block"
        if any(j::Int -> JS.kind(bas[i][j]) === JS.K"local", 1:JS.numchildren(bas[i]))
            # If this `block` contains `local`, it may introduce local bindings.
            # For correct scope analysis, we need to analyze this entire block
            break
        end
        # `bas[i]` is a block within a global scope, so can't introduce local bindings.
        # Shrink the tree (mostly for performance).
        i -= 1
        i < 1 && return nothing
    end
    return bas[i]
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
function Base.show(io::IO, tc::TokenCursor)
    print(io, "TokenCursor at position ", tc.position, " ")
    show(io, this(tc))
end
next_tok(tc::TokenCursor) =
    @something(iterate(tc, (tc.position, tc.next_byte)), return nothing)[1]
prev_tok(tc::TokenCursor) = tc.position <= 1 ? nothing :
    TokenCursor(tc.tokens, tc.position - 1, tc.next_byte - tc.tokens[tc.position].byte_span)
this(tc::TokenCursor) = tc.tokens[tc.position]
JS.first_byte(tc::TokenCursor) = tc.position <= 1 ? UInt32(1) : prev_tok(tc).next_byte
JS.last_byte(tc::TokenCursor) = tc.next_byte - UInt32(1)
JS.byte_range(tc::TokenCursor) = JS.first_byte(tc):JS.last_byte(tc)
JS.kind(tc::TokenCursor) = JS.kind(this(tc))

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
    JS.last_byte(@something prev_nontrivia(args...; kwargs...) return nothing)

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
    JS.first_byte(@something next_nontrivia(args...; kwargs...) return nothing)

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
    k = kind(tc)
    JS.is_whitespace(k) && (pass_newlines || k !== JS.K"NewlineWs")
end

"""
    get_line_indent(fi::FileInfo, byte_offset::Int) -> Union{String,Nothing}

Get the leading whitespace (indentation) at `byte_offset`.

Returns the indentation string when the position is at the start of a line
(after a newline or at the start of the file). Returns `nothing` when the
position is preceded by non-whitespace tokens on the same line, indicating
that the position is not at the beginning of a line.

# Examples
- `"    export a, b"` at byte 5 (start of `export`) → `"    "`
- `"begin\\n    export a, b"` at `export` → `"    "`
- `"begin export a, b"` at `export` → `nothing`
"""
function get_line_indent(fi::FileInfo, byte_offset::Int)
    prev_tc = prev_nontrivia(fi.parsed_stream, byte_offset; strict=true)
    if prev_tc === nothing
        return String(fi.parsed_stream.textbuf[1:byte_offset-1])
    elseif JS.kind(prev_tc) === JS.K"NewlineWs"
        # NewlineWs includes both newline and following whitespace (e.g., "\n    ")
        tok_text = fi.parsed_stream.textbuf[JS.byte_range(prev_tc)]
        newline_end = findlast(c::UInt8 -> c == UInt8('\n') || c == UInt8('\r'), tok_text)
        return newline_end === nothing ? "" : String(tok_text[newline_end+1:end])
    else
        return nothing
    end
end

# TODO: This is used so that `r"foo"|` or `r"foo" |` don't show signature help,
# but this edge case might be acceptable given that `r"foo" anything|` shouldn't
# show signature help
is_special_macrocall(st0::JS.SyntaxTree) =
    JS.kind(st0) === JS.K"macrocall" && JS.numchildren(st0) >= 1 &&
    let mname = kind(st0[1]) === JS.K"." && JS.numchildren(st0[1]) === 2 ? st0[1][2] : st0[1]
        mname_s = hasproperty(mname, :name_val) ? mname.name_val : ""
        endswith(mname_s, "_str") || endswith(mname_s, "_cmd")
    end

noparen_macrocall(st0::JS.SyntaxTree) =
    JS.kind(st0) === JS.K"macrocall" &&
    !JS.has_flags(st0, JS.PARENS_FLAG) &&
    !is_special_macrocall(st0)

"""
    select_target_identifier(st0::JS.SyntaxTree, offset::Int) -> target::Union{JS.SyntaxTree,Nothing}

Determines the node that the user most likely intends to navigate to.
Returns `nothing` if no suitable one is found.
Currently `st0` needs to be a `SyntaxTree` before lowering.

Currently, it simply checks the ancestors of the node located at the given offset.

TODO: Apply a heuristic similar to rust-analyzer
refs:
- https://github.com/rust-lang/rust-analyzer/blob/6acff6c1f8306a0a1d29be8fd1ffa63cff1ad598/crates/ide/src/goto_definition.rs#L47-L62
- https://github.com/aviatesk/JETLS.jl/pull/61#discussion_r2134707773
"""
function select_target_identifier(st0::JS.SyntaxTree, offset::Int)
    filter = function (bas)
        JS.is_identifier(first(bas))
    end
    selector = function (bas)
        target = first(bas)
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
    return select_target_node(filter, selector, st0, offset)
end

function select_target_string(st0::JS.SyntaxTree, offset::Int)
    filter = function (bas)
        JS.kind(first(bas)) === JS.K"String"
    end
    selector = function (bas)
        return first(bas)
    end
    return select_target_node(filter, selector, st0, offset)
end

function select_target_node(filter, selector, st0::JS.SyntaxTree, offset::Int)
    bas = @somereal byte_ancestors(st0, offset) @goto minus1
    if !filter(bas)
        @label minus1
        offset > 0 || return nothing
        # Support cases like `var│`, `func│(5)`
        bas = @somereal byte_ancestors(st0, offset - 1) return nothing
        if !filter(bas)
            return nothing
        end
    end
    return selector(bas)
end

"""
    select_dotprefix_identifier(st::JS.SyntaxTree, offset::Int) -> dotprefix::Union{JS.SyntaxTree,Nothing}

If the code at `offset` position is dot accessor code, get the code being dot accessed.
For example, `Base.show_│` returns the `SyntaxTree` of `Base`.
If it's not dot accessor code, return `nothing`.
"""
function select_dotprefix_identifier(st::JS.SyntaxTree, offset::Int)
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
            obj, fi::Union{FileInfo,SavedFileInfo};
            adjust_first::Int = 0, adjust_last::Int = 0
        ) -> range::LSP.Range

Returns the position information of a JuliaSyntax object in the source file in `LSP.Range` format.

# Arguments
- `obj`: A JuliaSyntax object with byte range information (typically a `SyntaxNode` or
  `SyntaxTree`, must respond to `JS.first_byte`, `JS.last_byte`, and `JS.kind`)
- `fi::FileInfo`: The file info containing the parsed content

# Keyword Arguments
- `adjust_first::Int = 0`: Adjustment to apply to the first byte position
- `adjust_last::Int = 0`: Adjustment to apply to the last byte position

# Returns
`LSP.Range`: The position range of the object in the source file, with character positions
calculated according to the specified encoding.

# Details
The function converts byte offsets from JuliaSyntax to LSP-compatible positions using
the encoding specified by `fi`.

Note that `+1` is added to `JS.last_byte(obj)` when calculating the end position
(additionally, if `adjust_last` is specified, that value is also added).
`JS.last_byte(obj)` returns the 1-based byte index of the last byte that belongs to
the object. To create a range that includes this byte, we need the position after it,
since LSP uses half-open intervals [start, end) where the end position is exclusive.
This follows the standard convention where the end position points to the first
character/byte that is NOT part of the range.
"""
function jsobj_to_range(
        obj, fi::Union{FileInfo,SavedFileInfo};
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
        if iszero(lb)
            epos = Position(; line=spos.line, character=Int(typemax(Int32)))
        else
            epos = offset_to_xy(fi, lb+1+adjust_last)
        end
        return Range(; start = spos, var"end" = epos)
    end
end

function try_extract_field_line(node::JS.SyntaxNode, structname::Symbol, fname::Symbol)
    if JS.kind(node) === JS.K"struct" && JS.numchildren(node) ≥ 2
        structnm = node[1]
        if JS.kind(structnm) === JS.K"<:" && JS.numchildren(structnm) ≥ 1
            structnm = structnm[1]
        end
        if JS.kind(structnm) === JS.K"curly" && JS.numchildren(structnm) ≥ 1
            structnm = structnm[1]
        end
        if (let data = structnm.data; data !== nothing && data.val === structname; end)
            for i = 1:JS.numchildren(node[2])
                retfield = field = node[2][i]
                if JS.kind(field) === JS.K"const" && JS.numchildren(field) ≥ 1
                    field = field[1]
                end
                if JS.kind(field) === JS.K"::" && JS.numchildren(field) ≥ 1
                    field = field[1]
                end
                if let data = field.data; data !== nothing && data.val === fname; end
                    return retfield
                end
            end
        end
        return nothing
    else
        for i = 1:JS.numchildren(node)
            return @something try_extract_field_line(node[i], structname, fname) continue
        end
        return nothing
    end
end
