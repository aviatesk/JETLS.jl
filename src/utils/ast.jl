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
function byte_ancestors(st::JL.SyntaxTree, rng::UnitRange{Int})
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
byte_ancestors(st::JL.SyntaxTree, byte::Int) = byte_ancestors(st, byte:byte)

function byte_ancestors(sn::JS.SyntaxNode, rng::UnitRange{Int})
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
byte_ancestors(sn::JS.SyntaxNode, byte::Int) = byte_ancestors(sn, byte:byte)

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

# TODO: Refactor for JuliaLang/JuliaSyntax.jl#560
"""
    get_current_token_idx(fi::FileInfo, offset::Int)

Get the current token index at a given byte offset in a parsed file.
This function returns the token at the specified byte offset, or `nothing`
if the offset is invalid or no token exists at that position.

Example:
- `al│pha beta gamma` (`b`=3) returns the index of `alpha`
- `│alpha beta gamma` (`b`=1) returns the index of `alpha`
- `alpha│ beta gamma` (`b`=6) returns the index of ` ` (whitespace)
- `alpha │beta gamma` (`b`=7) returns the index of `beta`
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
