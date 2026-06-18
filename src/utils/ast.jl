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
    if fi.syntax_tree0 === nothing
        st0 = JS.build_tree(JS.SyntaxTree, fi.parsed_stream; filename=fi.filename)
        return JS.prune(st0)
    end
    # The lowering pipeline modifies the internal state of `st0`,
    # so we need to create a copy for each read to avoid race conditions.
    return copy_syntax_tree(fi.syntax_tree0)
end

has_name_val(st::SyntaxTreeC) = JS.hasattr(st, :name_val)
get_name_val(st::SyntaxTreeC, default=nothing) = has_name_val(st) ? st.name_val::String : default
name_val(st::SyntaxTreeC) = st.name_val::String

var_id(st::SyntaxTreeC) = st.var_id::JL.IdTag

get_source_text(ps::JS.ParseStream) = JS.sourcetext(JS.SourceFile(ps))
document_text(fi::FileInfo) = get_source_text(fi.parsed_stream)
document_range(fi::FileInfo) = jsobj_to_range(fi.parsed_stream, fi)

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
    trim_error_nodes(st0::SyntaxTreeC) -> SyntaxTreeC

Strip parser-recovery (`K"error"`) nodes from `st0` and fix the structural shapes that
the strip would otherwise leave malformed for JuliaLowering — i.e. [`without_kinds`](@ref)
and [`repair_after_trim`](@ref) in sequence. Apply this to a surface AST before handing it
to a lowering pass that needs to tolerate incomplete user input.
"""
trim_error_nodes(st0::SyntaxTreeC) = repair_after_trim(without_kinds(st0, JS.KSet"error"))

function _without_kinds(st::SyntaxTreeC, kinds::Tuple{Vararg{JS.Kind}})
    if JS.kind(st) in kinds
        return (nothing, true)
    elseif JS.is_leaf(st)
        return (st, false)
    end
    new_children = JS.SyntaxList(JS.syntax_graph(st))
    changed = false
    for child in JS.children(st)
        new_child, child_changed = _without_kinds(child, kinds)
        changed |= child_changed
        isnothing(new_child) || push!(new_children, new_child)
    end
    # `mknode` copies all attrs (kind, syntax_flags, value, ...) from `st`, so
    # we don't lose the parser's infix/prefix tagging that downstream repair
    # passes need to disambiguate trimmed `(:: x)` from anonymous `(:: T)`.
    new_node = changed ? JS.mknode(st, new_children) : st
    return (new_node, changed)
end

"""
    without_kinds(st::SyntaxTreeC, kinds::Tuple{Vararg{JS.Kind}}) -> trimmed::SyntaxTreeC

Return a tree where all nodes of `kinds` are trimmed.
Should not modify any nodes, and should not create new nodes unnecessarily.
"""
function without_kinds(st::SyntaxTreeC, kinds::Tuple{Vararg{JS.Kind}})
    ensure_jl_source_attr!(JS.syntax_graph(st))
    return (JS.kind(st) in kinds ?
        JL.@ast(JS.syntax_graph(st), st, [JS.K"TOMBSTONE"]) :
        _without_kinds(st, kinds)[1])::SyntaxTreeC
end

"""
    repair_after_trim(st0::SyntaxTreeC) -> SyntaxTreeC

Walk `st0` and fix structural shapes that JuliaLowering would reject after
[`without_kinds`](@ref) has trimmed parser-recovery (`K"error"`) nodes. Each
repair rule replaces a now-malformed parent with a substitute (typically one
of its surviving children) so that downstream passes can keep processing the
surrounding tree.

Currently handled:

- `K"."` — `lhs.│` parses as `(. lhs (inert (error)))`; after trim the empty
  `K"inert"` makes JuliaLowering reject the dot as "invalid `.` syntax", so
  the node is collapsed to `lhs`.
- `K"&&"` / `K"||"` — short-circuit nodes that always carry ≥ 2 operands in valid parses.
  A single-child residue (e.g. `(&& a)` from `a &&│`) trips a `numchildren > 1` assertion
  in JuliaLowering, so the node is collapsed to its surviving operand.
- `K"::"` — collapses 1-child residue to its lhs only for the infix form (`value::│`);
  the anonymous prefix form (`f(::T)`) keeps its lone child intact.

Not yet handled because the malformed shape needs more than a child-collapse:

- `K"->"`, `K"if"`, `K"for"`, compound-assignment `K"unknown_head"` — either a
  structural rewrite or context-aware reasoning is required.

Add new branches in [`_repair_node`](@ref) when these cause downstream
breakage in practice.
"""
function repair_after_trim(st0::SyntaxTreeC)
    ensure_jl_source_attr!(JS.syntax_graph(st0))
    return _repair_after_trim(st0)::SyntaxTreeC
end

function _repair_after_trim(st0::SyntaxTreeC)
    JS.is_leaf(st0) && return st0
    new_children = JS.SyntaxList(JS.syntax_graph(st0))
    changed = false
    for child in JS.children(st0)
        new_child = _repair_after_trim(child)
        push!(new_children, new_child)
        changed |= new_child !== child
    end
    repaired = _repair_node(st0, new_children)
    repaired !== nothing && return repaired
    return changed ? JS.mknode(st0, new_children) : st0
end

# Per-kind repair rules. Each rule returns the replacement node when it applies,
# or `nothing` to fall through to the default reconstruction.
function _repair_node(st0::SyntaxTreeC, new_children::JS.SyntaxList)
    k = JS.kind(st0)
    if k === JS.K"." && length(new_children) == 2 && _is_empty_non_leaf(new_children[2])
        return new_children[1]
    end
    if k in JS.KSet"&& ||" && length(new_children) == 1
        return new_children[1]
    end
    # `(:: x)` can mean either a trimmed `value::│` (infix, the user was typing
    # a type annotation) or an anonymous `::T` (prefix, valid as a function
    # arg slot). The parser's infix/prefix flag — preserved through trimming
    # by `JS.mknode` — disambiguates them, so we only collapse the infix case.
    if k === JS.K"::" && length(new_children) == 1 && JS.is_infix_op_call(st0)
        return new_children[1]
    end
    return nothing
end

_is_empty_non_leaf(st0::SyntaxTreeC) = !JS.is_leaf(st0) && JS.numchildren(st0) == 0

"""
Return a tree where `JS.K"\$"` interpolation nodes are replaced by their content.
Unlike `without_kinds` which removes nodes entirely, this preserves the child
so that parent nodes (e.g. dot expressions like `x.\$name`) remain well-formed.
"""
function _unwrap_interpolations(st::SyntaxTreeC)
    if JS.kind(st) === JS.K"$"
        if JS.numchildren(st) >= 1
            new_child, _ = _unwrap_interpolations(st[1])
            return (new_child, true)
        end
        return (st, false)
    elseif JS.is_leaf(st)
        return (st, false)
    end
    new_children = JS.SyntaxList(JS.syntax_graph(st))
    changed = false
    for child in JS.children(st)
        new_child, child_changed = _unwrap_interpolations(child)
        changed |= child_changed
        push!(new_children, new_child)
    end
    k = JS.kind(st)
    # Preserve `name_val` when reconstructing: kinds like `K"unknown_head"`
    # (used by compound assignments such as `+=`) carry the operator name in
    # `name_val`, and JuliaLowering's validator requires it to be present.
    new_node = if !changed
        st
    elseif has_name_val(st)
        JL.@ast(JS.syntax_graph(st), st, [k(name_val=name_val(st)) new_children...])
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
    nv = if has_name_val(macro_name)
        name_val(macro_name)
    else
        JS.sourcetext(macro_name)
    end
    return nv in names && (isnothing(from) || (JS.hasattr(macro_name, :mod) && macro_name.mod === from))
end

is_mainfunc0(st0::SyntaxTreeC) = is_macrocall_st0(st0, "@main")

is_generated0(st0::SyntaxTreeC) = is_macrocall_st0(st0, "@generated")

is_nospecialize_or_specialize_macrocall0(st0::SyntaxTreeC) =
    is_macrocall_st0(st0, "@nospecialize", "@specialize")

is_macro0(st0::SyntaxTreeC) = JS.kind(st0) === JS.K"macro"

is_new_style_macrocall0(st0::SyntaxTreeC) =
    is_macrocall_st0(st0, NEW_STYLE_MACROCALL_NAMES...)

is_doc0(st0::SyntaxTreeC) = is_macrocall_st0(st0, "@doc"; from=Core)
is_doc0_any(st0::SyntaxTreeC) = is_macrocall_st0(st0, "@doc") # Explicit `@doc` can have any module set.

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
    is_import_eval_call(st3::SyntaxTreeC) -> Bool

Return `true` when `st3` is a `K"call"` to JuliaLowering's `eval_import` /
`eval_using` runtime helpers, which `import` / `using` statements desugar into.
The module-path components are carried as `K"inert"` arguments of these calls.
Because they are compiler-generated rather than user-authored quoted code, inert
traversals skip such calls so module paths are not mistaken for ordinary global
references (e.g. `import A.B` nested in an `if`/`begin` block).
"""
function is_import_eval_call(st3::SyntaxTreeC)
    JS.kind(st3) === JS.K"call" || return false
    JS.numchildren(st3) ≥ 1 || return false
    head = st3[1]
    JS.kind(head) === JS.K"Value" || return false
    val = head.value
    return val === JL.eval_import || val === JL.eval_using
end

"""
    foreach_inert_identifier(callback, st::SyntaxTreeC)

Traverse `st` looking for `K"inert"` nodes, and call `f(id_node)` for each
`K"Identifier"` found inside them. `callback` should return `true` to continue
traversal or `false` to stop early.
"""
function foreach_inert_identifier(@specialize(callback), st::SyntaxTreeC)
    res = traverse(st) do n
        # Skip `import`/`using` desugaring (see `is_import_eval_call`).
        is_import_eval_call(n) && return traversal_no_recurse
        JS.kind(n) === JS.K"inert" || return
        inner = traverse(n) do m
            JS.kind(m) === JS.K"Identifier" || return
            callback(m) || return TraversalReturn(false; terminate=true)
            return
        end
        inner === false && return TraversalReturn(false; terminate=true)
        return traversal_no_recurse
    end
    return res !== false
end

function find_inert_identifier(st::SyntaxTreeC, offset::Integer)
    found = Ref{Union{Nothing,SyntaxTreeC}}(nothing)
    foreach_inert_identifier(st) do id_node::SyntaxTreeC
        if offset in JS.byte_range(id_node)
            found[] = id_node
            return false
        end
        return true
    end
    return found[]
end

function find_inert_identifier_name(st::SyntaxTreeC, offset::Integer)
    id_node = @something find_inert_identifier(st, offset) return nothing
    return get_name_val(id_node)
end

function is_nospecialize_or_specialize_macrocall3(st3::SyntaxTreeC)
    JS.kind(st3) === JS.K"macrocall" || return false
    JS.numchildren(st3) >= 1 || return false
    macro_name = st3[1]
    JS.kind(macro_name) === JS.K"macro_name" || return false
    JS.numchildren(st3) >= 2 || return false
    macro_name = macro_name[2]
    JS.kind(macro_name) === JS.K"Identifier" || return false
    return get_name_val(macro_name) in ("nospecialize", "specialize")
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
    elseif has_name_val(st0)
        JL.@ast(JS.syntax_graph(st0), st0, [k(name_val=name_val(st0)) new_children...])
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

# Iteratively peel a function-definition signature's `where {…}` clauses and outer `::T`
# return-type annotation, returning the innermost unwrapped node — usually a `K"call"`, but
# callers should check (e.g. `f::Int = …` peels to a `K"Identifier"`). Parameter type
# annotations like `f(x::T)` live inside the call's args, so this pass doesn't touch them.
# On malformed input (a wrapper with no children) the wrapper is returned as-is, so callers'
# kind checks naturally filter it without a separate `nothing` branch.
function unwrap_funcdef_sig(node::SyntaxTreeC)
    while true
        k = JS.kind(node)
        if (k === JS.K"where" || k === JS.K"::") && JS.numchildren(node) ≥ 1
            node = node[1]
        else
            return node
        end
    end
end

# Collect the `name_val` of every `K"Identifier"` node reachable from `st` into `names`.
function collect_identifier_names!(names::Set{String}, st::SyntaxTreeC)
    traverse(st) do node
        if JS.kind(node) === JS.K"Identifier"
            name = get_name_val(node)
            name === nothing || push!(names, name)
        end
        return
    end
    return names
end

# `K"core"` leaves can't appear in user-written source (`Core.x` lowers through
# `K"globalref"`), so these match only lowering-generated references.
function is_core_ref(node::SyntaxTreeC, name::String)
    return JS.kind(node) === JS.K"core" && get_name_val(node) == name
end

function is_core_svec_call(call_node::SyntaxTreeC)
    JS.numchildren(call_node) >= 1 || return false
    return is_core_ref(call_node[1], "svec")
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
        # Force inlining: keeps the callback's branches inside this loop, lets
        # LLVM fold the small-Union return-tag dispatch, and avoids the
        # per-iteration GC root spill that a Julia call boundary requires
        ret = @inline callback(x)
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
        # See the `_traverse_preorder` comment above
        ret = @inline callback(x)
        if ret isa TraversalReturn
            retval = ret.val
            ret.terminate ? break : continue
        end
        ret === traversal_terminator && break
    end
    return retval
end

# TODO use something like `JuliaInterpreter.ExprSplitter`

"""
    iterate_toplevel_tree(callback, st0_top::SyntaxTreeC)

Walk each lowerable top-level subtree of `st0_top` (descending into `K"toplevel"`,
`K"module"`, and docstring wrappers) and invoke `callback(st0)` on every leaf.

The `callback` can control iteration by returning one of:
- `traversal_terminator`: stop iteration immediately.
- `TraversalReturn(val)`: store `val` as the return value and continue.
- `TraversalReturn(val; terminate=true)`: store `val` and stop immediately.
- anything else: continue.

The stored value from the last `TraversalReturn` is returned (or `nothing` if no
`TraversalReturn` was used).
"""
function iterate_toplevel_tree(callback, st0_top::SyntaxTreeC)
    retval = nothing
    sl = JS.SyntaxList(st0_top)
    while !isempty(sl)
        st0 = pop!(sl)
        if JS.kind(st0) === JS.K"toplevel"
            for i = JS.numchildren(st0):-1:1 # reversed since we use `pop!`
                push!(sl, st0[i])
            end
        elseif JS.kind(st0) === JS.K"module"
            # The body `K"block"` is typically the last child, but trailing
            # `K"error"` nodes from incomplete code can push it earlier.
            stblk_idx = @something findlast(i::Int -> JS.kind(st0[i]) === JS.K"block",
                1:JS.numchildren(st0)) continue
            stblk = st0[stblk_idx]
            for i = JS.numchildren(stblk):-1:1 # reversed since we use `pop!`
                push!(sl, stblk[i])
            end
        elseif is_doc0_any(st0)
            # Dispatch the macro arguments of a `@doc` macrocall as their own
            # lowerable trees:
            # - the documented expression is reached directly, so cursor-based features and
            #   per-statement diagnostics keep accurate source positions, which otherwise
            #   could be lost during the expansion of `@doc` (an old-style macro)
            # - the docstring node (a `K"string"` with interpolations as children) is
            #   lowered too, so identifier interpolations like `$(SIGNATURES)` from
            #   `DocStringExtensions` resolve as global `:use` occurrences
            for i = JS.numchildren(st0):-1:3 # reversed since we use `pop!`
                # The first two children of any macrocall are the macro name and the line
                # node, both of which carry the macrocall's full byte range as provenance
                # and would otherwise capture cursor-based lookups for any offset inside
                # the doc-wrapped form; start at `i = 3` to skip them.
                push!(sl, st0[i])
            end
        else # st0 is lowerable tree
            ret = callback(st0)
            if ret isa TraversalReturn
                retval = ret.val
                ret.terminate ? break : continue
            end
            ret === traversal_terminator && break
        end
    end
    return retval
end

"""
    byte_ancestors([flt,] st::SyntaxTreeC, rng::UnitRange{Int})
    byte_ancestors([flt,] st::SyntaxTreeC, byte::Integer)

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
    lowerable_toplevel_at(st0_top::SyntaxTreeC, offset::Integer) -> st::Union{SyntaxTreeC, Nothing}

Return the lowerable top-level subtree of `st0_top` whose byte range contains `offset`, or
`nothing` if no such subtree exists. Equivalent to running [`iterate_toplevel_tree`](@ref)
and picking the first hit whose byte range contains `offset`, with an `offset - 1` retry
for cursor positions just past the last token of a statement (e.g. `export foo│\\n`).
"""
function lowerable_toplevel_at(st0_top::SyntaxTreeC, offset::Integer)
    result = _lowerable_toplevel_at(st0_top, offset)
    result !== nothing && return result
    return offset > 1 ? _lowerable_toplevel_at(st0_top, offset - 1) : nothing
end

function _lowerable_toplevel_at(st0_top::SyntaxTreeC, offset::Integer)
    return iterate_toplevel_tree(st0_top) do st0::SyntaxTreeC
        offset in JS.byte_range(st0) || return nothing
        return TraversalReturn(st0; terminate=true)
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
function Base.show(io::IO, tc::TokenCursor)
    print(io, "TokenCursor at position ", tc.position, " ")
    show(io, this(tc))
end
next_tok(tc::TokenCursor) =
    @something(iterate(tc, (tc.position, tc.next_byte)), return nothing)[1]
prev_tok(tc::TokenCursor) = tc.position <= 1 ? nothing :
    TokenCursor(tc.tokens, tc.position - 1, tc.next_byte - tc.tokens[tc.position].byte_span)
this(tc::TokenCursor) = tc.tokens[tc.position]
JS.first_byte(tc::TokenCursor) = tc.position <= 1 ? 1 : Int(prev_tok(tc).next_byte)
JS.last_byte(tc::TokenCursor) = Int(tc.next_byte) - 1
JS.byte_range(tc::TokenCursor) = JS.first_byte(tc):JS.last_byte(tc)
JS.kind(tc::TokenCursor) = JS.kind(this(tc))

"""
    token_at_offset(fi::FileInfo, offset::Integer)

Get the current token index at a given byte offset in a parsed file.

Example:
- `al│pha beta gamma` (`b`=3) returns the index of `alpha`
- `│alpha beta gamma` (`b`=1) returns the index of `alpha`
- `alpha│ beta gamma` (`b`=6) returns the index of ` ` (whitespace)
- `alpha │beta gamma` (`b`=7) returns the index of `beta`
"""
function token_at_offset(ps::JS.ParseStream, offset::Integer)
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
token_before_offset(ps::JS.ParseStream, offset::Integer) = token_at_offset(ps, offset - 1)
token_before_offset(fi::FileInfo, pos::Position) =
    token_before_offset(fi.parsed_stream, xy_to_offset(fi, pos))

"""
    prev_nontrivia_byte(ps::JS.ParseStream, b::Integer; pass_newlines::Bool=false, strict::Bool=false)

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
    prev_nontrivia(ps::JS.ParseStream, b::Integer; pass_newlines::Bool=false, strict::Bool=false)

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
    next_nontrivia_byte(ps::JS.ParseStream, b::Integer; pass_newlines::Bool=false, strict::Bool=false)

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
    next_nontrivia(ps::JS.ParseStream, b::Integer; pass_newlines=false, strict=false)

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

function find_nontrivia(prev_or_next::Bool, ps::JS.ParseStream, b::Integer; pass_newlines::Bool=false, strict::Bool=false)
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
    k = JS.kind(tc)
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
    let mname = JS.kind(st0[1]) === JS.K"." && JS.numchildren(st0[1]) === 2 ? st0[1][2] : st0[1]
        mname_s = get_name_val(mname, "")
        endswith(mname_s, "_str") || endswith(mname_s, "_cmd")
    end

noparen_macrocall(st0::SyntaxTreeC) =
    JS.kind(st0) === JS.K"macrocall" &&
    !JS.has_flags(st0, JS.PARENS_FLAG) &&
    !is_special_macrocall(st0)

"""
    select_target_identifier(st0::SyntaxTreeC, offset::Integer) -> target::Union{SyntaxTreeC,Nothing}

Determine the identifier node that the user most likely intends to navigate to,
or `nothing` if no suitable one is found. `st0` must be a `SyntaxTree` before
lowering.

For dot expressions, walks up through `K"."` to pick the larger dotted prefix
(`Base.Compi│ler.tmeet` → `Base.Compiler`). Cursor positions at token boundaries
like `var│` or `func│(5)` are handled by [`select_target_node`](@ref)'s
`offset - 1` fallback.
"""
function select_target_identifier(st0::SyntaxTreeC, offset::Integer)
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

function select_target_string(st0::SyntaxTreeC, offset::Integer)
    filter = function (bas)
        JS.kind(first(bas)) === JS.K"String"
    end
    selector = function (bas)
        return first(bas)
    end
    return select_target_node(filter, selector, st0, offset)
end

"""
    select_enclosing_call(st0::SyntaxTreeC, offset::Integer) ->
        target::Union{SyntaxTreeC, Nothing}

Innermost surface form whose value is the result of a callable application
whose byte range contains `offset`. Covers:

- `K"call"` / `K"dotcall"` — `f(args)`, `obj.f(args)`
- `K"ref"` — `arr[idx]`, `T[a, b, c]` (typed comma-separated literal)
- `K"tuple"` — `(a, b, c)`
- `K"vect"` — `[a, b, c]`
- `K"vcat"` / `K"hcat"` — `[a; b]` / `[a b]`
- `K"comprehension"` — `[x for y in z]`
- `K"typed_vcat"` / `K"typed_hcat"` / `K"typed_comprehension"` — typed
  variants of the above

All of these lower to a `K"call"` (`getindex`, `Core.tuple`, `Base.vect`,
`Base.vcat`, `Base.hcat`, `Base.collect`, …) and so carry an inferred
return type that downstream features can query.

Probes both `offset` and `offset - 1`, picking the more specific (smaller
byte range) match when both yield a hit. This makes `func(args)│` and
`outer(inner(x)│)` symmetric — both resolve to the form that just closed
at the cursor, rather than to whichever enclosing form also happens to
span that byte.
"""
function select_enclosing_call(st0::SyntaxTreeC, offset::Integer)
    a = _innermost_call_at(st0, offset)
    offset > 0 || return a
    b = _innermost_call_at(st0, offset - 1)
    a === nothing && return b
    b === nothing && return a
    return length(JS.byte_range(a)) <= length(JS.byte_range(b)) ? a : b
end

"""
    _OPERATOR_CALL_KINDS

Non-`K"call"` / `K"dotcall"` surface kinds whose lowered form is a single
dispatched operator: `xs[i]│` → `getindex`, `(a, b)│` → `Core.tuple`,
`[a, b]│` → `Base.vect`, `[a; b]│` → `Base.vcat`, `[a for x in xs]│` →
`Base.collect`, etc. Used by features that want to look up the dispatched
method directly from the surface (go-to-definition Phase 4, hover
operator-dispatch doc, …) — the surface's own byte range maps to the
lowered call's `:matches` annotation without any walk-up.
"""
const _OPERATOR_CALL_KINDS = JS.KSet"""
    ref tuple vect vcat hcat comprehension
    typed_vcat typed_hcat typed_comprehension
    """

const _CALL_LIKE_KINDS = JS.KSet"""
    call dotcall ref tuple vect vcat hcat comprehension
    typed_vcat typed_hcat typed_comprehension
    """

function _innermost_call_at(st0::SyntaxTreeC, offset::Integer)
    for b in byte_ancestors(st0, offset)
        JS.kind(b) in _CALL_LIKE_KINDS && return b
    end
    return nothing
end

"""
    enclosing_call_for_matches(st0::SyntaxTreeC, node::SyntaxTreeC) ->
        SyntaxTreeC | nothing

Call node whose `:matches` annotation answers a query about `node`.
Returns `nothing` when `node` isn't (and isn't the callee of) a call.

Two recognized shapes:
- `node` itself is `K"call"` / `K"dotcall"` (`func(args)│`) — returns `node`.
- `node` is the full callee of an enclosing call (`func│(args)`, `Foo.bar│(args)`) —
  returns the enclosing call.

`byte_ancestors` walks from the cursor outward; the first call whose `child[1]` byte range
exactly matches `node`'s range is the call we want.
The exact-match check rejects mid-callee positions like `Foo│.bar(x)` where `node` is
`Foo` and `child[1]` is the larger `Foo.bar`.
"""
function enclosing_call_for_matches(st0::SyntaxTreeC, node::SyntaxTreeC)
    JS.kind(node) in JS.KSet"call dotcall" && return node
    rng = JS.byte_range(node)
    for st in byte_ancestors(st0, first(rng))
        JS.kind(st) in JS.KSet"call dotcall" || continue
        JS.numchildren(st) >= 1 || continue
        JS.byte_range(st[1]) == rng && return st
    end
    return nothing
end

"""
    select_target_for_type_query(st0::SyntaxTreeC, offset::Integer) ->
        target::Union{SyntaxTreeC, Nothing}

Pick the AST node whose `JS.byte_range` should be passed to `get_type_for_range` for the
cursor at `offset`. Falls back through:

1. [`select_target_identifier`](@ref) — handles identifiers and dot-chain expressions
   (`Base.Compi│ler.tmeet` → `Base.Compiler`).
2. [`select_enclosing_call`](@ref) — handles cursor positions that aren't on an identifier
   but are inside (or right after) a call expression (`func(args)│` → the `func(args)` call,
   whose type is the call's return type).

Intended as the canonical cursor → AST resolver for TypeAnnotation-based features
(type definition, hover-type, etc.).
"""
select_target_for_type_query(st0::SyntaxTreeC, offset::Integer) =
    @something(
        select_target_identifier(st0, offset),
        return select_enclosing_call(st0, offset))

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
    value isa String || return nothing
    path = joinpath(basedir, value)
    ispath(path) || return nothing
    return (; value, path)
end

function select_target_node(filter, selector, st0::SyntaxTreeC, offset::Integer)
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
    select_dotprefix_identifier(st::SyntaxTreeC, offset::Integer) -> dotprefix::Union{SyntaxTreeC,Nothing}

If the code at `offset` position is dot accessor code, get the code being dot accessed.
For example, `Base.show_│` returns the `SyntaxTree` of `Base`.
If it's not dot accessor code, return `nothing`.
"""
function select_dotprefix_identifier(st::SyntaxTreeC, offset::Integer)
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
            adjust_first::Integer = 0, adjust_last::Integer = 0
        ) -> range::LSP.Range

Returns the position information of a JuliaSyntax object in the source file in `LSP.Range` format.

# Arguments
- `obj`: A JuliaSyntax object with byte range information (typically a `SyntaxNode` or
  `SyntaxTree`, must respond to `JS.first_byte`, `JS.last_byte`, and `JS.kind`)
- `fi::FileInfo`: The file info containing the parsed content

# Keyword Arguments
- `adjust_first::Integer = 0`: Adjustment to apply to the first byte position
- `adjust_last::Integer = 0`: Adjustment to apply to the last byte position

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
        adjust_first::Integer = 0, adjust_last::Integer = 0
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
        binfo = JL.get_binding(ctx3, var_id(func))
        binfo.kind === :global && Symbol(binfo.name) in allow_noreturn_optimization && return true
    end
    for i in 2:JS.numchildren(st3)
        is_noreturn_call(ctx3, st3[i], allow_noreturn_optimization) && return true
    end
    return false
end
