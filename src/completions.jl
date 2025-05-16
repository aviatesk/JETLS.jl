using .JS: @K_str, @KSet_str

const SORT_TEXT_0 = "00000000"
const SORT_TEXT_1 = "00000001"

# completion utils
# ================

function completion_is(ci::CompletionItem, ckind::Symbol)
    # `ckind` is :global, :local, :argument, or :sparam.  Implementation likely
    # to change with changes to the information we put in CompletionItem.
    ci.labelDetails.description === String(ckind) ||
        (ci.labelDetails.description === "argument" && ckind === :local)
end

# local completions
# =================

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
Get a list of `SyntaxTree`s containing certain bytes.  Output should be
topologically sorted, children first.

If we know that parent ranges contain all child ranges, and that siblings don't
have overlapping ranges (this is not true after lowering, but appear to be true
after parsing), each tree in the result will be a child of the next.
"""
function byte_ancestors(st::JL.SyntaxTree, b::Int, b2::Int=b)
    function byte_ancestors_(st::JL.SyntaxTree, l::JL.SyntaxList)
        (JS.numchildren(st) === 0) && return l
        cis = findall(ci -> (b in JS.byte_range(ci) && b2 in JS.byte_range(ci)),
                      JS.children(st))
        append!(l, map(ci -> st[ci], cis))
        for c in JS.children(st)
            var"#self#"(c, l)
        end
        return l
    end

    # delete later duplicates when sorted parent->child
    out = deduplicate_syntaxlist(byte_ancestors_(st, JL.SyntaxList(st._graph, [st._id])))
    return reverse(out)
end

byte_ancestors(st0::JL.SyntaxTree, r::UnitRange{Int}) = byte_ancestors(st0, r.start, r.stop)

"""
Find any largest lowerable tree containing the cursor and the cursor's position
within it.  For local completions; something like least_unlowerable would be
more helpful for globals.
"""
function greatest_lowerable(st0::JL.SyntaxTree, b::Int)
    bas = byte_ancestors(st0, b)
    i = findfirst(st -> JL.kind(st) in KSet"toplevel module inert", bas)
    if isempty(bas) || i === 1
        return (nothing, b)
    elseif isnothing(i)
        # shouldn't happen outside of testing (parseall wraps with toplevel)
        gl = last(bas)
    else
        gl = bas[i - 1]
    end
    return gl, (b - (JS.first_byte(st0) - 1))
end

"""
Heuristic for showing completions.  A binding is relevant when it isn't internal
(compiler-generated) and is defined before the cursor.
"""
function is_relevant(ctx::JL.AbstractLoweringContext,
                     binding::JL.BindingInfo,
                     cursor::Int)
    !binding.is_internal &&
        (binding.kind === :global
         # || we could relax this for locals defined before the end of the
         #    largest for/while containing the cursor
         || cursor > JS.byte_range(JL.binding_ex(ctx, binding.id)).start)
end

"""
Find the list of (JL.BindingInfo, JL.LambdaBindingInfo|nothing, SyntaxTree)
to suggest as completions given a parsed SyntaxTree and a cursor position.

JuliaLowering throws away the mapping from scopes to bindings (scopes are stored
as an ephemeral stack.)  We work around this by taking all available bindings
and filtering out any that aren't declared in a scope containing the cursor.
"""
function cursor_bindings(st0_top::JL.SyntaxTree, b_top::Int)
    st0, b = greatest_lowerable(st0_top, b_top)
    if isnothing(st0)
        return nothing # nothing we can lower
    end
    # julia does require knowing what module we're lowering in, but it isn't
    # needed for reasonable completions
    ctx1, st1 = JL.expand_forms_1(Module(), st0);
    ctx2, st2 = JL.expand_forms_2(ctx1, st1);
    ctx3, st3 = JL.resolve_scopes(ctx2, st2);

    # Note that ctx.bindings are only available after resolve_scopes, and
    # scope-blocks are not present in st3 after resolve_scopes.
    binfos = filter(binfo -> is_relevant(ctx3, binfo, b), ctx3.bindings.info)

    # for each binding: binfo, all syntaxtrees containing it, and the scope it belongs to
    bscopeinfos = Tuple{JL.BindingInfo, JL.SyntaxList, Union{JL.SyntaxTree, Nothing}}[]
    for binfo in binfos
        # TODO: find tree parents instead of byte parents?
        bas = byte_ancestors(st2, JS.byte_range(JL.binding_ex(ctx3, binfo.id)))
        # find the innermost hard scope containing this binding decl.  we shouldn't
        # be in multiple overlapping scopes that are not direct ancestors; that
        # should indicate a provenance failure
        i = findfirst(ba -> JS.kind(ba) in KSet"scope_block lambda module toplevel", bas)
        push!(bscopeinfos, (binfo, bas, isnothing(i) ? nothing : bas[i]))
    end

    cursor_scopes = byte_ancestors(st2, b)

    # ignore scopes we aren't in
    filter!(((binfo, _, bs),) -> isnothing(bs) || bs._id in cursor_scopes.ids,
            bscopeinfos)

    # Now eliminate duplicates by name.
    # - Prefer any local binding belonging to a tighter scope (lower bdistance)
    # - If a static parameter and a local of the same name exist in the same
    #   scope (impossible in julia), the local is internal and should be ignored
    bdistances = map(((_, _, bs),) -> if isnothing(bs)
                         lastindex(cursor_scopes.ids) + 1
                     else
                         findfirst(cs -> bs._id === cs, cursor_scopes.ids)
                     end,
                     bscopeinfos)

    seen = Dict{String, Int}()
    for i in eachindex(bscopeinfos)
        (binfo, _, _) = bscopeinfos[i]

        prev = get(seen, binfo.name, nothing)
        if (isnothing(prev)
            || bdistances[i] < bdistances[prev]
            || binfo.kind === :static_parameter)
            seen[binfo.name] = i
        else
            @info "Found two bindings with the same name:" binfo bscopeinfos[prev][1]
        end
    end

    # TODO sort by bdistance?

    return map(values(seen)) do i
        (binfo, bas, _) = bscopeinfos[i]

        # Get LambdaBindingInfo from nearest lambda, if any
        ba_lam = findfirst(st -> kind(st) === K"lambda", bas)
        lbs = isnothing(ba_lam) ? nothing : get(bas[ba_lam], :lambda_bindings, nothing)
        lb = isnothing(lbs)     ? nothing : get(lbs.bindings, binfo.id, nothing)
        return (binfo, JL.binding_ex(ctx3, binfo.id), lb)
    end
end

"""
# Typical completion UI

to|
   ┌───┬──────────────────────────┬────────────────────────────┐
   │(1)│to_completion(2)     (3) >│(4)...                      │
   │(1)│to_indices(2)        (3)  │# Typical completion UI ─(5)│
   │(1)│touch(2)             (3)  │                          │ │
   └───┴──────────────────────────┤to|                       │ │
                                  │...                     ──┘ │
                                  └────────────────────────────┘
(1) Icon corresponding to CompletionItem's `ci.kind`
(2) `ci.labelDetails.detail`
(3) `ci.labelDetails.description`
(4) `ci.detail`
(5) `ci.documentation`

Sending (4) and (5) to the client can happen eagerly in response to <TAB>
(textDocument/completion), or lazily, on selection in the list
(completionItem/resolve).  The LSP specification notes that more can be deferred
in later versions.
"""
function to_completion(binding::JL.BindingInfo,
                       st::JL.SyntaxTree,
                       lb::Union{Nothing, JL.LambdaBindingInfo}=nothing)
    label_kind = CompletionItemKind.Variable
    label_detail = nothing
    label_desc = nothing
    detail = nothing
    documentation = nothing

    if binding.is_const
        label_kind = CompletionItemKind.Constant
    elseif binding.kind === :static_parameter
        label_kind = CompletionItemKind.TypeParameter
    end

    if binding.kind in [:argument, :local, :global]
        label_desc = String(binding.kind)
    elseif binding.kind === :static_parameter
        label_desc = "sparam"
    end

    if !isnothing(binding.type)
        label_detail = "::" * JL.sourcetext(binding.type)
    end

    if !isnothing(lb) && lb.is_called
        label_kind = CompletionItemKind.Function
    end

    detail = sprint(JL.showprov, st)

    CompletionItem(;
        label = binding.name,
        labelDetails = CompletionItemLabelDetails(;
            detail = label_detail,
            description = label_desc),
        kind = label_kind,
        detail,
        documentation,
        sortText = SORT_TEXT_0, # show local completions first
        data = CompletionData(#=needs_resolve=#false))
end

function local_completions!(items::Dict{String, CompletionItem},
                            s::ServerState, uri::URI, pos::Position)
    fi = get_fileinfo(s, uri)
    fi === nothing && return items
    st0 = JS.build_tree(JL.SyntaxTree, fi.parsed_stream)
    cbs = cursor_bindings(st0, xy_to_offset(fi, pos))
    cbs === nothing && return items
    for (bi, st, lb) in cbs
        ci = to_completion(bi, st, lb)
        prev_ci = get(items, ci.label, nothing)
        # Name collisions: overrule existing global completions with our own,
        # unless our completion is also a global, in which case the existing
        # completion from JET will have more information.
        if isnothing(prev_ci) || (completion_is(prev_ci, :global) && !completion_is(ci, :global))
            items[ci.label] = ci
        end
    end
    return items
end

# global completions
# ==================

function find_file_module!(state::ServerState, uri::URI, pos::Position)
    mod = find_file_module(state, uri, pos)
    state.completion_module[] = mod
    return mod
end
function find_file_module(state::ServerState, uri::URI, pos::Position)
    haskey(state.contexts, uri) || return Main
    contexts = state.contexts[uri]
    context = first(contexts)
    for ctx in contexts
        # prioritize `PackageSourceAnalysisEntry` if exists
        if isa(context.entry, PackageSourceAnalysisEntry)
            context = ctx
            break
        end
    end
    haskey(context.analyzed_file_infos, uri) || return Main
    analyzed_file_info = context.analyzed_file_infos[uri]
    curline = Int(pos.line) + 1
    _, idx = findmin(analyzed_file_info.module_range_infos) do (range, mod)
        curline in range || return typemax(Int)
        return last(range) - first(range)
    end
    return last(analyzed_file_info.module_range_infos[idx])
end

function global_completions!(items::Dict{String, CompletionItem}, state::ServerState, uri::URI, pos::Position)
    mod = find_file_module!(state, uri, pos)
    for name in names(mod; all=true, imported=true, usings=true)
        s = String(name)
        startswith(s, "#") && continue
        items[s] = CompletionItem(;
            label = s,
            labelDetails = CompletionItemLabelDetails(;
                description = "global"),
            kind = CompletionItemKind.Variable,
            documentation = nothing,
            sortText = SORT_TEXT_1,
            data = CompletionData(#=needs_resolve=#true))
    end
    return items
end

# completion resolver
# ===================

function resolve_completion_item(state::ServerState, item::CompletionItem)
    isassigned(state.completion_module) || return item
    data = item.data
    data isa CompletionData || return item
    data.needs_resolve || return item
    mod = state.completion_module[]
    name = Symbol(item.label)
    binding = Base.Docs.Binding(mod, name)
    docs = Base.Docs.doc(binding)
    return CompletionItem(;
        label = item.label,
        labelDetails = item.labelDetails,
        kind = item.kind,
        detail = item.detail,
        sortText = item.sortText,
        documentation = MarkupContent(;
            kind = MarkupKind.Markdown,
            value = string(docs)))
end

# request handler
# ===============

function get_completion_items(state::ServerState, uri::URI, pos::Position)
    items = Dict{String, CompletionItem}()
    # order matters; see local_completions!
    global_completions!(items, state, uri, pos)
    local_completions!(items, state, uri, pos)
    return collect(values(items))
end

function handle_CompletionRequest(s::ServerState, msg::CompletionRequest)
    uri = URI(msg.params.textDocument.uri)
    items = get_completion_items(s, uri, msg.params.position)
    return s.send(
        ResponseMessage(;
            id = msg.id,
            result = CompletionList(;
                isIncomplete = false,
                items)))
end

function handle_CompletionResolveRequest(s::ServerState, msg::CompletionResolveRequest)
    return s.send(
        ResponseMessage(;
            id = msg.id,
            result = resolve_completion_item(s, msg.params)))
end
