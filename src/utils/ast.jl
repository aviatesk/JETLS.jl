# Lightweight copy function for SyntaxTree
# This copies the SyntaxGraph's mutable structures (edge_ranges, edges, attributes)
# but shares the immutable data within attribute dictionaries
function copy_syntax_tree(st::SyntaxTreeC)
    g = JS.syntax_graph(st)
    new_attrs = Dict{Symbol,Dict{JL.IdTag,Any}}()
    for (k, v) in pairs(g.attributes)
        new_attrs[k] = copy(v)
    end
    new_graph = JS.SyntaxGraph(copy(g.edge_ranges), copy(g.edges), new_attrs)
    return SyntaxTreeC(new_graph, st._id)
end

function build_syntax_tree(fi::FileInfo)
    cached = fi.syntax_tree0
    if isnothing(cached)
        return JS.build_tree(JS.SyntaxTree, fi.parsed_stream; filename = fi.filename)
    else
        # The lowering pipeline modifies the internal state of `st0`,
        # so we need to create a copy for each read to avoid race conditions
        return copy_syntax_tree(cached)
    end
end

@static if JL.DEBUG
    function ensure_jl_source_attr!(graph::JS.SyntaxGraph)
        attrs = getfield(graph, :attributes)
        if !haskey(attrs, :jl_source)
            attrs[:jl_source] = Dict{Int,LineNumberNode}()
        end
    end
else
    ensure_jl_source_attr!(::JS.SyntaxGraph) = nothing
end

"""
Return a tree where all nodes of `kinds` are removed.  Should not modify any
nodes, and should not create new nodes unnecessarily.
"""
function _without_kinds(st::SyntaxTreeC, kinds::Tuple{Vararg{JS.Kind}})
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

function without_kinds(st::SyntaxTreeC, kinds::Tuple{Vararg{JS.Kind}})
    ensure_jl_source_attr!(JS.syntax_graph(st))
    return (JS.kind(st) in kinds ?
        JL.@ast(JS.syntax_graph(st), st, [JS.K"TOMBSTONE"]) :
        _without_kinds(st, kinds)[1])::SyntaxTreeC
end

"""
Return a tree where `K"\$"` interpolation nodes are replaced by their content.
Unlike `without_kinds` which removes nodes entirely, this preserves the child
so that parent nodes (e.g. dot expressions like `x.\$name`) remain well-formed.
"""
function _unwrap_interpolations(st::SyntaxTreeC)
    if JS.kind(st) === JS.K"$"
        if JS.numchildren(st) >= 1
            nc, _ = _unwrap_interpolations(st[1])
            return (nc, true)
        end
        return (st, false)
    elseif JS.is_leaf(st)
        return (st, false)
    end
    new_children = JS.SyntaxList(JS.syntax_graph(st))
    changed = false
    for c in JS.children(st)
        nc, cc = _unwrap_interpolations(c)
        changed |= cc
        push!(new_children, nc)
    end
    k = JS.kind(st)
    # Preserve `name_val` when reconstructing: kinds like `K"unknown_head"`
    # (used by compound assignments such as `+=`) carry the operator name in
    # `name_val`, and JuliaLowering's validator requires it to be present.
    new_node = if !changed
        st
    elseif hasproperty(st, :name_val)
        JL.@ast(JS.syntax_graph(st), st, [k(name_val=st.name_val::String) new_children...])
    else
        JL.@ast(JS.syntax_graph(st), st, [k new_children...])
    end
    return (new_node, changed)
end

function unwrap_interpolations(st::SyntaxTreeC)
    ensure_jl_source_attr!(JS.syntax_graph(st))
    return _unwrap_interpolations(st)[1]
end

function is_macrocall_st0(st0::SyntaxTreeC, names::AbstractString...; from::Union{Nothing,Module}=nothing)
    JS.kind(st0) === JS.K"macrocall" || return false
    JS.numchildren(st0) >= 1 || return false
    macro_name = st0[1]
    JS.kind(macro_name) === JS.K"Identifier" || return false
    hasproperty(macro_name, :name_val) || return false
    name_val = macro_name.name_val
    name_val isa String || return false
    return name_val in names && (isnothing(from) || (JS.hasattr(macro_name, :mod) && macro_name.mod === from))
end

is_mainfunc0(st0::SyntaxTreeC) = is_macrocall_st0(st0, "@main")

is_generated0(st0::SyntaxTreeC) = is_macrocall_st0(st0, "@generated")

is_macro0(st0::SyntaxTreeC) = JS.kind(st0) === JS.K"macro"

# Simple (non-qualified) macro names whose new-style implementations in
# `JuliaLowering/src/syntax_macros.jl` and `src/utils/jl-syntax-macros.jl`
# preserve fine-grained source provenance during expansion. Unlike old-style
# macros — whose expansion collapses source positions to line granularity and
# is why `_remove_macrocalls` exists — these don't need to be rewritten to a
# `block` to keep accurate locations for scope resolution.
const NEW_STYLE_MACROCALL_NAMES = (
    # JuliaLowering/src/syntax_macros.jl
    "@__FUNCTION__",
    "@ccall",
    "@cfunction",
    "@eval",
    "@generated",
    "@goto",
    "@isdefined",
    "@locals",
    "@nospecialize",
    # src/utils/jl-syntax-macros.jl
    "@kwdef",
    "@label",
    "@something",
    "@spawn",
    "@specialize",
    "@test",
    "@testset",
)

is_new_style_macrocall0(st0::SyntaxTreeC) =
    is_macrocall_st0(st0, NEW_STYLE_MACROCALL_NAMES...)

is_doc0(st0::SyntaxTreeC) = is_macrocall_st0(st0, "@doc"; from=Core)

is_cmd0(st0::SyntaxTreeC) = is_macrocall_st0(st0, "@cmd"; from=Core)

"""
    collect_import_names(st0::SyntaxTreeC) -> Vector{Pair{SyntaxTreeC, String}}

Return pairs of `(node, sort_key)` for the named items of an
`import`/`using`/`export`/`public` statement: the child node representing
each item alongside its sort key (see [`get_import_sort_key`](@ref)).
For `using M: a, b` returns entries for `a` and `b`; for `using M.A` (no
`:`) returns entries for the imported path nodes.
"""
function collect_import_names(st0::SyntaxTreeC)
    kind = JS.kind(st0)
    names = Pair{SyntaxTreeC, String}[]
    if kind in JS.KSet"import using"
        nchildren = JS.numchildren(st0)
        if nchildren == 1
            child = st0[1]
            if JS.kind(child) === JS.K":"
                for i = 2:JS.numchildren(child)
                    name = child[i]
                    push!(names, name => get_import_sort_key(name))
                end
            end
        elseif nchildren > 1
            for i = 1:nchildren
                name = st0[i]
                push!(names, name => get_import_sort_key(name))
            end
        end
    elseif kind in JS.KSet"export public"
        for i = 1:JS.numchildren(st0)
            name = st0[i]
            push!(names, name => get_import_sort_key(name))
        end
    end
    return names
end

"""
    foreach_local_import_identifier(f, st0::SyntaxTreeC)

Invoke `f(id_st)` once for each locally-introduced identifier of an
`import`/`using` statement `st0`. Covers every form that actually binds
a name in the current scope:

- `using A` / `import A` — `A`
- `using A, B` / `import A, B` — `A`, `B`
- `using A.B` / `import A.B` / `using .A.B` — the trailing component
- `using A: x, y` / `import A: x, y` — each listed name
- `using A: x as y` — the alias `y`
- `import A: x as y` — likewise
"""
function foreach_local_import_identifier(f, st0::SyntaxTreeC)
    kind = JS.kind(st0)
    kind in JS.KSet"import using" || return
    nchildren = JS.numchildren(st0)
    if nchildren == 1 && JS.kind(st0[1]) === JS.K":"
        child = st0[1]
        for i = 2:JS.numchildren(child)
            id_st = get_local_import_identifier(child[i])
            id_st === nothing || f(id_st)
        end
    else
        # Direct children are `K"."` paths (one per comma-separated module),
        # e.g. `using A` → `[K"."(A)]`, `using A, B` → `[K"."(A), K"."(B)]`,
        # `using .A.B` → `[K"."(., A, B)]`. The locally-introduced name is the
        # last component of each path.
        for i = 1:nchildren
            id_st = get_local_import_identifier(st0[i])
            id_st === nothing || f(id_st)
        end
    end
    return
end

"""
    get_local_import_identifier(st0::SyntaxTreeC) -> Union{SyntaxTreeC, Nothing}

Return the `K"Identifier"` node that represents the local binding introduced
by a single element of an `import`/`using` statement, or `nothing` if the
element is not a well-formed name path. Accepts both the top-level module
path children (`using A.B` → path `A.B`) and the names listed after `:`
(`using A: foo` → path `foo`):
- path with a bare `Identifier` — the identifier itself
- dotted path `K"."` — the trailing component (skipping the relative `.`
  or `..` prefixes of forms like `.A` / `..A.B`)
- `K"as"` (inside a colon list) — the alias
"""
function get_local_import_identifier(st0::SyntaxTreeC)
    kind = JS.kind(st0)
    if kind === JS.K"as"
        # `using M: a as b` -> identifier for "b"
        return st0[2]
    elseif kind === JS.K"Identifier"
        return st0
    elseif kind === JS.K"."
        npath = JS.numchildren(st0)
        if npath >= 1
            last_st = st0[npath]
            if JS.kind(last_st) === JS.K"Identifier"
                return last_st
            end
        end
        return nothing
    else
        return nothing
    end
end

function get_import_sort_key(st0::SyntaxTreeC)
    kind = JS.kind(st0)
    if kind === JS.K"as"
        return get_import_sort_key(st0[1])
    elseif kind === JS.K"."
        parts = String[]
        for i = 1:JS.numchildren(st0)
            child = st0[i]
            ckind = JS.kind(child)
            if ckind === JS.K"Identifier"
                push!(parts, JS.sourcetext(child))
            end
        end
        return join(parts, ".")
    elseif kind === JS.K"Identifier"
        return JS.sourcetext(st0)
    else
        return JS.sourcetext(st0)
    end
end

"""
    foreach_inert_identifier(callback, st::SyntaxTreeC)

Traverse `st` looking for `K"inert"` nodes, and call `f(id_node)` for each
`K"Identifier"` found inside them. `callback` should return `true` to continue
traversal or `false` to stop early.
"""
function foreach_inert_identifier(callback, node::SyntaxTreeC)
    if JS.kind(node) === JS.K"inert"
        foreach_identifier_in_inert(callback, node) || return false
    else
        for child in JS.children(node)
            foreach_inert_identifier(callback, child) || return false
        end
    end
    return true
end
function foreach_identifier_in_inert(callback, node::SyntaxTreeC)
    if JS.kind(node) === JS.K"Identifier"
        callback(node) || return false
    end
    for child in JS.children(node)
        foreach_identifier_in_inert(callback, child) || return false
    end
    return true
end

function find_inert_identifier_name(st::SyntaxTreeC, offset::Int)
    name = Ref{Union{Nothing,String}}(nothing)
    foreach_inert_identifier(st) do id_node::SyntaxTreeC
        if offset in JS.byte_range(id_node)
            JS.hasattr(id_node, :name_val) || return true
            name_val = id_node.name_val
            name_val isa AbstractString || return true
            name[] = name_val
            return false
        end
        return true
    end
    return name[]
end

function is_nospecialize_or_specialize_macrocall3(st3::SyntaxTreeC)
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

function _remove_macrocalls(st0::SyntaxTreeC)
    if JS.kind(st0) === JS.K"macrocall"
        if is_new_style_macrocall0(st0)
            # Macros with new-style JuliaLowering implementations preserve
            # fine-grained provenance during expansion, so we don't need to
            # rewrite them to a `block` to keep source locations accurate.
            # See `NEW_STYLE_MACROCALL_NAMES` for the list.
            return st0, false
        elseif is_mainfunc0(st0)
            # `@main` functions are desugared by `desugar_main_macrocall` below,
            # so there's no need to remove them here
            return st0, false
        elseif is_doc0(st0)
            return _remove_macrocalls(st0[end])[1], true
        elseif is_cmd0(st0)
            # `` `foo` `` parses to `Core.@cmd(LineNumberNode, CmdString)` where
            # `CmdString` is an opaque leaf JuliaLowering has no rule for at
            # statement position. Strip-to-block would result in lowering failure,
            # so leave the macrocall intact and let `Core.@cmd` expansion run.
            # Expansion collapses interpolations' provenance, which means features like
            # rename/references can't pinpoint a name used inside a cmd literal --
            # but binding occurrence analysis still get correct results.
            return st0, false
        end
        new_children = JS.SyntaxList(JS.syntax_graph(st0))
        for i = 2:JS.numchildren(st0)
            # `$` interpolations at macrocall-argument position are legal only
            # because the macro will typically splice the argument into a
            # `quote`/`:(...)` (`@eval`, code-generating macros, user-defined
            # macros that build a quoted expression, etc.). Once we lift the
            # arguments out of the macrocall into a bare `block`, any surviving
            # `$` would be out of context and fail lowering, so unwrap
            # interpolations on the lifted child.
            stripped, _ = _remove_macrocalls(st0[i])
            push!(new_children, _unwrap_interpolations(stripped)[1])
        end
        return JL.@ast(JS.syntax_graph(st0), st0, [JS.K"block" new_children...]), true
    elseif JS.is_leaf(st0)
        return st0, false
    end
    (st0, changed) = desugar_main_macrocall(st0)
    new_children = JS.SyntaxList(JS.syntax_graph(st0))
    for c in JS.children(st0)
        nc, cc = _remove_macrocalls(c)
        changed |= cc
        push!(new_children, nc)
    end
    k = JS.kind(st0)
    # Preserve `name_val` when reconstructing: kinds like `K"unknown_head"`
    # (used by compound assignments such as `+=`) carry the operator name in
    # `name_val`, and JuliaLowering's validator requires it to be present.
    new_node = if !changed
        st0
    elseif hasproperty(st0, :name_val)
        JL.@ast(JS.syntax_graph(st0), st0, [k(name_val=st0.name_val::String) new_children...])
    else
        JL.@ast(JS.syntax_graph(st0), st0, [k new_children...])
    end
    return (new_node, changed)
end

"""
    desugar_main_macrocall(st0::SyntaxTreeC) -> Tuple{SyntaxTreeC, Bool}

If `st0` is a `function (@main)(args...) ... end`, `(@main)(args...) = ...`,
`function @main(args...) ... end`, or `@main(args...) = ...` definition, replace
the `@main` macrocall with a plain `main` identifier and return the rewritten
tree with `true`. Otherwise return `(st0, false)`.
This avoids macro expansion failure when multiple standalone files defining
`@main` are analyzed in the same session — the second file's sandbox module
already has `main` imported from the first, causing `@main` expansion to error.
"""
function desugar_main_macrocall(st0::SyntaxTreeC)
    k = JS.kind(st0)
    if k === JS.K"function"
        JS.numchildren(st0) >= 1 || return (st0, false)
        call_node = st0[1]
    elseif k === JS.K"="
        JS.numchildren(st0) >= 2 || return (st0, false)
        call_node = st0[1]
    else
        return (st0, false)
    end
    if JS.kind(call_node) === JS.K"call"
        # Parenthesized form: (@main)(args...) — macrocall is the callee
        JS.numchildren(call_node) >= 1 || return (st0, false)
        is_mainfunc0(call_node[1]) || return (st0, false)
        g = JS.syntax_graph(st0)
        main_id = JS.setattr!(
            JS.newleaf(g, call_node[1], JS.K"Identifier"), :name_val, "main")
        new_call_children = JS.SyntaxList(g)
        push!(new_call_children, main_id)
        for i in 2:JS.numchildren(call_node)
            push!(new_call_children, call_node[i])
        end
        new_call = JS.newnode(g, call_node, JS.K"call", new_call_children)
    elseif is_mainfunc0(call_node)
        # No-parens form: @main(args...) — entire signature is a macrocall
        g = JS.syntax_graph(st0)
        main_id = JS.setattr!(
            JS.newleaf(g, call_node[1], JS.K"Identifier"), :name_val, "main")
        new_call_children = JS.SyntaxList(g)
        push!(new_call_children, main_id)
        for i in 2:JS.numchildren(call_node)
            JS.kind(call_node[i]) === JS.K"Value" && continue
            push!(new_call_children, call_node[i])
        end
        new_call = JS.newnode(g, call_node, JS.K"call", new_call_children)
    else
        return (st0, false)
    end
    new_children = JS.SyntaxList(g)
    push!(new_children, new_call)
    for i in 2:JS.numchildren(st0)
        push!(new_children, st0[i])
    end
    return (JS.newnode(g, st0, k, new_children), true)
end

"""
    remove_macrocalls(st0::SyntaxTreeC) -> SyntaxTreeC

Convert each `macrocall` node to a `block` node, keeping the arguments intact so that
identifiers passed to macros retain their original source locations. The transformed
tree can then be fed into scope/binding resolution to drive LSP features such as
find-references, document-highlight, rename, and go-to-definition.

This is useful because JuliaLowering's macro expansion (for old-style macros) loses
fine-grained provenance information, reducing it to line-level granularity. For example,
in `@noop foo`, highlighting `foo` would incorrectly highlight `@noop foo` entirely
if macro expansion were performed. By removing macrocalls before lowering, we preserve
precise source locations for bindings outside of macrocalls, at the cost of discarding
any bindings or control flow the macros themselves would have introduced.

!!! note "Usage scope"
    The transformed tree is intended only for scope/binding resolution. It
    intentionally does not preserve semantic validity: replacing a macrocall with a
    raw `block` can place statements like `return` into expression contexts that are
    not legal Julia (e.g. `x = (begin ...; return nothing; end)`). Feeding the
    transformed tree into flow-sensitive analyses such as `analyze_local_def_use!`
    or `analyze_unreachable!` can therefore produce nonsensical results and must
    be avoided.

!!! note "Assumption on macro behavior"
    Macros are treated as if `@m expr` behaved like `begin expr end` — i.e. they
    neither introduce new syntactic structures, bind new names, nor alter control
    flow. Macros that merely rewrite control flow (e.g. `@something`/`@assert`
    into conditional `return`/`throw`) are a known limitation rather than a
    handled case: scope resolution on the transformed tree can be incorrect in
    their vicinity — e.g. reachability and post-macro-only bindings — though it
    still yields useful results for source-level LSP features in practice.

!!! note "Future direction"
    This transform is a workaround for old-style macros that lose provenance
    during expansion. Macros with new-style JuliaLowering implementations (listed
    in `NEW_STYLE_MACROCALL_NAMES`) already preserve provenance and are therefore
    exempt from removal, and `@main` is handled separately by
    `desugar_main_macrocall`. As more macros migrate to the new style, the scope
    of this transformation is expected to shrink.
"""
function remove_macrocalls(st0::SyntaxTreeC)
    ensure_jl_source_attr!(JS.syntax_graph(st0))
    return first(_remove_macrocalls(st0))
end

function unwrap_where(node::SyntaxTreeC)
    while JS.kind(node) === JS.K"where" && JS.numchildren(node) ≥ 1
        node = node[1]
    end
    return node
end

extract_name_val(node::SyntaxTreeC) =
    hasproperty(node, :name_val) ? node.name_val::String : nothing

# Collect the `name_val` of every `K"Identifier"` node reachable from `st` into `names`.
function collect_identifier_names!(names::Set{String}, st::SyntaxTreeC)
    traverse(st) do node
        if JS.kind(node) === JS.K"Identifier"
            name = get(node, :name_val, nothing)
            name === nothing || push!(names, name::String)
        end
        return
    end
    return names
end

"""
Like `Base.unique`, but over node ids, and with this comment promising that the
lowest-index copy of each node is kept.
"""
function deduplicate_syntaxlist(sl::SyntaxListC)
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

"""
    traverse(callback, st::SyntaxTreeC, postorder::Bool=false)

Traverse a `SyntaxTree`, calling `callback(node)` on each node.
By default traverses in pre-order (parent before children).
Pass `postorder=true` to visit children before their parent.

The `callback` can control traversal by returning one of:
- `traversal_terminator`: stop traversal immediately.
- `traversal_no_recurse`: skip children of the current node (pre-order only).
- `TraversalReturn(val)`: store `val` as the return value and continue.
- `TraversalReturn(val; terminate=true)`: store `val` and stop immediately.
- anything else: continue normally.

The stored value from the last `TraversalReturn` is returned from `traverse`
(or `nothing` if no `TraversalReturn` was used).
"""
function traverse(@specialize(callback), st::SyntaxTreeC, postorder::Bool=false)
    stack = JS.SyntaxList(st)
    if postorder
        _traverse_postorder(callback, stack)
    else
        _traverse_preorder(callback, stack)
    end
end

struct TraversalReturn{T}
    val::T
    terminate::Bool
    TraversalReturn(val::T; terminate::Bool=false) where T = new{T}(val, terminate)
end
struct TraversalTerminator end
struct TraversalNoRecurse end
const traversal_terminator = TraversalTerminator()
const traversal_no_recurse = TraversalNoRecurse()

function _traverse_preorder(@specialize(callback), stack::SyntaxListC)
    local retval = nothing
    while !isempty(stack)
        x = pop!(stack)
        ret = callback(x)
        if ret isa TraversalReturn
            retval = ret.val
            ret.terminate ? break : continue
        end
        ret === traversal_terminator && break
        ret === traversal_no_recurse && continue
        if JS.numchildren(x) === 0
            continue
        end
        for i = JS.numchildren(x):-1:1
            push!(stack, x[i])
        end
    end
    return retval
end

function _traverse_postorder(@specialize(callback), stack::SyntaxListC)
    local retval = nothing
    output = JS.SyntaxList(stack.graph)
    while !isempty(stack)
        x = pop!(stack)
        push!(output, x)
        for i = 1:JS.numchildren(x)
            push!(stack, x[i])
        end
    end
    while !isempty(output)
        x = pop!(output)
        ret = callback(x)
        if ret isa TraversalReturn
            retval = ret.val
            ret.terminate ? break : continue
        end
        ret === traversal_terminator && break
    end
    return retval
end

# TODO use something like `JuliaInterpreter.ExprSplitter`

function iterate_toplevel_tree(callback, st0_top::SyntaxTreeC)
    sl = JS.SyntaxList(st0_top)
    while !isempty(sl)
        st0 = pop!(sl)
        if JS.kind(st0) === JS.K"toplevel"
            for i = JS.numchildren(st0):-1:1 # reversed since we use `pop!`
                push!(sl, st0[i])
            end
        elseif JS.kind(st0) === JS.K"module"
            stblk = st0[end]
            JS.kind(stblk) === JS.K"block" || continue
            for i = JS.numchildren(stblk):-1:1 # reversed since we use `pop!`
                push!(sl, stblk[i])
            end
        elseif is_doc0(st0)
            # Analyze only the code to which docstrings are attached
            push!(sl, st0[end])
        else # st0 is lowerable tree
            ret = callback(st0)
            ret === traversal_terminator && break
        end
    end
end

"""
    byte_ancestors([flt,] st::SyntaxTreeC, rng::UnitRange{Int})
    byte_ancestors([flt,] st::SyntaxTreeC, byte::Int)

Get a SyntaxList of `SyntaxTree`s containing certain bytes.

Output should be topologically sorted, children first.  If we know that parent
ranges contain all child ranges, and that siblings don't have overlapping ranges
(this is not true after lowering, but appears to be true after parsing), each
tree in the result will be a child of the next.

An optional filter function `flt` can be provided to include only nodes
that satisfy the predicate.
"""
byte_ancestors(args...) = byte_ancestors(Returns(true), args...)

function byte_ancestors(flt, st::SyntaxTreeC, rng::UnitRange{<:Integer})
    sl = JS.SyntaxList(JS.syntax_graph(st))
    if rng ⊆ JS.byte_range(st) && flt(st)
        push!(sl, st)
    end
    traverse(st) do st′
        # EST `K"Value"` nodes can share the same byte range as their parent
        # (e.g. module's baremodule flag, struct's mutability flag).
        # Skip them to avoid polluting the ancestor chain.
        JS.kind(st′) === JS.K"Value" && return nothing
        if rng ⊆ JS.byte_range(st′) && flt(st′)
            push!(sl, st′)
        end
    end
    # delete later duplicates when sorted parent->child
    return reverse!(deduplicate_syntaxlist(sl))
end
byte_ancestors(flt, st::SyntaxTreeC, byte::Integer) = byte_ancestors(flt, st, byte:byte)

"""
    greatest_local(st0::SyntaxTreeC, offset::Int) -> st::Union{SyntaxTreeC, Nothing}

Return the largest tree that can introduce local bindings that are visible to the cursor
(if any such tree exists).
"""
function greatest_local(st0::SyntaxTreeC, offset::Int)
    result = _find_greatest_local(st0, offset)
    result !== nothing && return result
    # When the cursor sits just past the last token of a line (e.g. `export
    # foo│\n`), `offset` points at a byte owned only by `toplevel`, so the
    # initial lookup yields nothing. Retry with `offset - 1` to select the
    # node just to the left of the cursor, mirroring the offset-1 fallbacks
    # in `_select_target_binding` / `select_macrocall_binding`.
    return offset > 1 ? _find_greatest_local(st0, offset - 1) : nothing
end

function _find_greatest_local(st0::SyntaxTreeC, offset::Int)
    bas = byte_ancestors(st0, offset)
    first_global = @something begin
        findfirst(st::SyntaxTreeC -> JS.kind(st) in JS.KSet"toplevel module", bas)
    end return nothing
    if first_global == 1
        return nothing
    end
    idx = Ref(first_global - 1)
    while JS.kind(bas[idx[]]) === JS.K"block"
        if any(j::Int -> JS.kind(bas[idx[]][j]) === JS.K"local", 1:JS.numchildren(bas[idx[]]))
            # If this `block` contains `local`, it may introduce local bindings.
            # For correct scope analysis, we need to analyze this entire block
            break
        end
        # `bas[i]` is a block within a global scope, so can't introduce local bindings.
        # Shrink the tree (mostly for performance).
        idx[] -= 1
        idx[] < 1 && return nothing
    end
    return bas[idx[]]
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
    get_line_indent(fi::FileInfo, line::Integer) -> String

Get the leading whitespace (indentation) of the given 0-indexed line.

# Examples
- `"    export a, b"` line 0 → `"    "`
- `"begin\\n    export a, b"` line 1 → `"    "`
- `"begin\\n    export a, b"` line 0 → `""`
"""
function get_line_indent(fi::FileInfo, line::Integer)
    textbuf = fi.parsed_stream.textbuf
    byte = xy_to_offset(fi, Position(; line, character = 0))
    n = length(textbuf)
    i = byte
    while i <= n
        b = textbuf[i]
        b == UInt8(' ') || b == UInt8('\t') || break
        i += 1
    end
    return String(textbuf[byte:i-1])
end

# TODO: This is used so that `r"foo"|` or `r"foo" |` don't show signature help,
# but this edge case might be acceptable given that `r"foo" anything|` shouldn't
# show signature help
is_special_macrocall(st0::SyntaxTreeC) =
    JS.kind(st0) === JS.K"macrocall" && JS.numchildren(st0) >= 1 &&
    let mname = kind(st0[1]) === JS.K"." && JS.numchildren(st0[1]) === 2 ? st0[1][2] : st0[1]
        mname_s = hasproperty(mname, :name_val) ? mname.name_val : ""
        endswith(mname_s, "_str") || endswith(mname_s, "_cmd")
    end

noparen_macrocall(st0::SyntaxTreeC) =
    JS.kind(st0) === JS.K"macrocall" &&
    !JS.has_flags(st0, JS.PARENS_FLAG) &&
    !is_special_macrocall(st0)

"""
    select_target_identifier(st0::SyntaxTreeC, offset::Int) -> target::Union{SyntaxTreeC,Nothing}

Determines the node that the user most likely intends to navigate to.
Returns `nothing` if no suitable one is found.
Currently `st0` needs to be a `SyntaxTree` before lowering.

Currently, it simply checks the ancestors of the node located at the given offset.

TODO: Apply a heuristic similar to rust-analyzer
refs:
- https://github.com/rust-lang/rust-analyzer/blob/6acff6c1f8306a0a1d29be8fd1ffa63cff1ad598/crates/ide/src/goto_definition.rs#L47-L62
- https://github.com/aviatesk/JETLS.jl/pull/61#discussion_r2134707773
"""
function select_target_identifier(st0::SyntaxTreeC, offset::Int)
    filter = function (bas)
        JS.is_identifier(first(bas))
    end
    selector = function (bas)
        target = first(bas)
        for i = 2:length(bas)
            basᵢ = bas[i]
            # EST wraps the RHS identifier of dot expressions in `K"inert"`
            JS.kind(basᵢ) === JS.K"inert" && continue
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

function select_target_string(st0::SyntaxTreeC, offset::Int)
    filter = function (bas)
        JS.kind(first(bas)) === JS.K"String"
    end
    selector = function (bas)
        return first(bas)
    end
    return select_target_node(filter, selector, st0, offset)
end

"""
    resolve_path_string_literal(string_node::SyntaxTreeC, basedir::AbstractString)
        -> Union{Nothing, @NamedTuple{value::String, path::String}}

If `string_node` is a non-interpolated string literal whose value joins with
`basedir` to form an existing path, return its raw `value` and the resolved
`path`. Otherwise return `nothing`.
"""
function resolve_path_string_literal(
        string_node::SyntaxTreeC, basedir::AbstractString
    )
    JS.hasattr(string_node, :value) || return nothing
    value = string_node.value
    value isa AbstractString || return nothing
    path = joinpath(basedir, value)
    ispath(path) || return nothing
    return (; value = String(value), path = String(path))
end

function select_target_node(filter, selector, st0::SyntaxTreeC, offset::Int)
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
    select_dotprefix_identifier(st::SyntaxTreeC, offset::Int) -> dotprefix::Union{SyntaxTreeC,Nothing}

If the code at `offset` position is dot accessor code, get the code being dot accessed.
For example, `Base.show_│` returns the `SyntaxTree` of `Base`.
If it's not dot accessor code, return `nothing`.
"""
function select_dotprefix_identifier(st::SyntaxTreeC, offset::Int)
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

"""
    line_absorbing_delete_range(obj, fi::FileInfo) -> Range

Build a delete range covering the bytes of `obj`. When `obj` is the only
non-whitespace content on its line, the range is extended to absorb the
surrounding indentation and the trailing newline so that deletion does not
leave a stray blank line behind. Otherwise, the result equals
[`jsobj_to_range(obj, fi)`](@ref jsobj_to_range).

Intended for `data.delete_range` of a `DeleteRangeData` quick-fix that
removes a whole statement (e.g. `using M: x`, `@label foo`).
"""
function line_absorbing_delete_range(obj, fi::FileInfo)
    fb = JS.first_byte(obj)
    lb = JS.last_byte(obj)
    textbuf = fi.parsed_stream.textbuf
    line_start = fb
    while line_start > 1 && textbuf[line_start - 1] != UInt8('\n')
        c = textbuf[line_start - 1]
        if c != UInt8(' ') && c != UInt8('\t')
            return jsobj_to_range(obj, fi)
        end
        line_start -= 1
    end
    after_end = lb + 1
    while after_end ≤ length(textbuf) && textbuf[after_end] != UInt8('\n')
        c = textbuf[after_end]
        if c != UInt8(' ') && c != UInt8('\t')
            return jsobj_to_range(obj, fi)
        end
        after_end += 1
    end
    if after_end ≤ length(textbuf) && textbuf[after_end] == UInt8('\n')
        after_end += 1
    end
    return Range(;
        start = offset_to_xy(fi, line_start),
        var"end" = offset_to_xy(fi, after_end))
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

"""
    is_from_user_ast(provs::SyntaxListC) -> Bool

Determine whether a binding with the given provenances originates from user-written code.

When a binding has multiple provenances (e.g., due to macro expansion), this function
checks if the final provenance location falls within the byte range of the first provenance.
If so, the binding likely corresponds to an identifier the user actually wrote, even though
it was processed by a macro.

This allows diagnostics to report on user-written identifiers like `x` in
`func(@nospecialize x) = ()`, while filtering out purely macro-generated bindings
like internal variables from `@ast`.

!!! note
    This currently does not support old-style macros due to JuliaLowering limitations.
"""
function is_from_user_ast(provs::SyntaxListC)
    length(provs) == 1 && return true
    fprov, lprov = first(provs), last(provs)
    JS.sourcefile(lprov) == JS.sourcefile(fprov) || return false
    return JS.byte_range(lprov) ⊆ JS.byte_range(fprov)
end

function is_noreturn_call(
        ctx3::JL.VariableAnalysisContext, st3::SyntaxTreeC,
        allow_noreturn_optimization::Vector{Symbol}
    )
    JS.kind(st3) === JS.K"call" || return false
    JS.numchildren(st3) >= 1 || return false
    func = st3[1]
    if JS.kind(func) === JS.K"BindingId"
        binfo = JL.get_binding(ctx3, func.var_id::JL.IdTag)
        binfo.kind === :global && Symbol(binfo.name) in allow_noreturn_optimization && return true
    end
    for i in 2:JS.numchildren(st3)
        is_noreturn_call(ctx3, st3[i], allow_noreturn_optimization) && return true
    end
    return false
end
