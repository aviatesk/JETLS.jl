# initialization
# ==============

const NUMERIC_CHARACTERS = tuple(string.('0':'9')...)
const METHOD_COMPLETION_TRIGGER_CHARACTERS = ("(", ",", " ")
const COMPLETION_TRIGGER_CHARACTERS = [
    "@",  # macro completion
    "\\", # LaTeX completion
    ":",  # emoji completion
    ";",  # keyword argument completion
    ".",  # property / module-member completion
    METHOD_COMPLETION_TRIGGER_CHARACTERS...,
    NUMERIC_CHARACTERS..., # allow these characters to be recognized by `CompletionContext.triggerCharacter`
]

completion_options() = CompletionOptions(;
    triggerCharacters = COMPLETION_TRIGGER_CHARACTERS,
    resolveProvider = true,
    completionItem = (;
        labelDetailsSupport = true))

const COMPLETION_REGISTRATION_ID = "jetls-completion"
const COMPLETION_REGISTRATION_METHOD = "textDocument/completion"

function completion_registration()
    (; triggerCharacters, resolveProvider, completionItem) = completion_options()
    return Registration(;
        id = COMPLETION_REGISTRATION_ID,
        method = COMPLETION_REGISTRATION_METHOD,
        registerOptions = CompletionRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
            triggerCharacters,
            resolveProvider,
            completionItem))
end

# For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id = COMPLETION_REGISTRATION_ID,
#     method = COMPLETION_REGISTRATION_METHOD))
# register(currently_running, completion_registration())

# completion utils
# ================

function completion_is(ci::CompletionItem, ckind::Symbol)
    # `ckind` is :global, :local, :argument, or :sparam.  Implementation likely
    # to change with changes to the information we put in CompletionItem.
    labelDetails = ci.labelDetails
    @assert labelDetails !== nothing
    return (labelDetails.description === String(ckind) ||
        (labelDetails.description === "argument" && ckind === :local))
end

# TODO use `let` block when Revise can handle it...
const sort_texts, max_sort_text = let
    sort_texts = Dict{Int, String}()
    for i = 1:1000
        sort_texts[i] = lpad(i, 4, '0')
    end
    _, max_sort_text = maximum(sort_texts)
    sort_texts, max_sort_text
end
const max_sort_text1 = "10000"
const max_sort_text2 = "100000"
const max_sort_text3 = "1000000"
function get_sort_text(offset::Int)
    return get(sort_texts, offset, max_sort_text)
end

# Per-request shared context
# ==========================

"""
    CompletionCtx

Per-request scratch space that the four completion routines (`call_completions!`,
`global_completions!`, `local_completions!`, `add_emoji_latex_completions!`) share.

Computes once and caches:
- syntax tree (`st0`) — feeding multiple routines that each used to call
  `build_syntax_tree(fi)` on their own.
- `get_context_info` projection — `context_module`, `world`, `postprocessor`.
- `offset` / `soft_scope` — derived from `pos` / `uri`.

Two heavier pieces are built lazily on first request:
- `InferredTreeContext` — shared between any routines that actually need
  type info at the cursor (always `call_completions!`, optionally
  `global_completions!` for dot-prefix). `build_inferred_context_for_range` keys
  off the toplevel statement containing the cursor, so a single context
  serves every routine here.
- `cursor_bindings` result — shared between `local_completions!` and the
  kwarg branch of `call_completions!`.

A future refactor that unifies `cursor_bindings` and `build_inferred_context_for_range`
at the `jl_lower_for_scope_resolution` level can replace the lazy accessors
without disturbing call sites.
"""
struct CompletionCtx
    state::ServerState
    uri::URI
    fi::FileInfo
    pos::Position
    context::Union{Nothing,CompletionContext}

    # Eagerly populated by the constructor.
    offset::Int
    st0_top::SyntaxTreeC
    context_module::Module
    world::UInt
    postprocessor::LSPostProcessor
    soft_scope::Bool

    # Lazy. `isassigned(ref)` distinguishes "not yet computed" from
    # "computed but the underlying build returned `nothing`".
    inferred_ctx::Base.RefValue{Union{Nothing,InferredTreeContext}}
    cursor_bindings::Base.RefValue{Union{Nothing,Vector{Tuple{JL.BindingInfo,SyntaxTreeC,Int}}}}
end

function CompletionCtx(
        state::ServerState, uri::URI, fi::FileInfo, pos::Position,
        context::Union{Nothing,CompletionContext};
        context_module::Union{Nothing,Module} = nothing
    )
    st0_top = build_syntax_tree(fi)
    info = get_context_info(state, uri, pos)
    context_mod = something(context_module, info.context_module)
    offset = xy_to_offset(fi, pos)
    soft_scope = is_notebook_cell_uri(state, uri)
    return CompletionCtx(state, uri, fi, pos, context,
        offset, st0_top, context_mod, info.world, info.postprocessor, soft_scope,
        Base.RefValue{Union{Nothing,InferredTreeContext}}(),
        Base.RefValue{Union{Nothing,Vector{Tuple{JL.BindingInfo,SyntaxTreeC,Int}}}}())
end

# Why not query the inferred-context cache with `offset:offset` directly:
# It filters toplevel subtrees by `rng ⊆ JS.byte_range(toplevel)`, and the
# cursor can sit past the toplevel's `last_byte` in incomplete code (e.g.
# `sin(42,│\n` — parser ends the `K"call"` at byte 7, cursor at byte 8 is
# outside). `lowerable_toplevel_at` has an `offset - 1` retry that handles
# this, so we go through it and pass the toplevel's actual byte range.
function get_inferred_ctx!(comp_ctx::CompletionCtx; caller::AbstractString)
    isassigned(comp_ctx.inferred_ctx) && return comp_ctx.inferred_ctx[]
    toplevel = lowerable_toplevel_at(comp_ctx.st0_top, comp_ctx.offset)
    ctx = if toplevel === nothing
        nothing
    else
        build_inferred_context_for_range(
            comp_ctx.st0_top, comp_ctx.context_module, JS.byte_range(toplevel);
            world=comp_ctx.world, caller, cache=comp_ctx.fi.inferred_context_cache)
    end
    return comp_ctx.inferred_ctx[] = ctx
end

function get_cursor_bindings_cached!(comp_ctx::CompletionCtx)
    isassigned(comp_ctx.cursor_bindings) && return comp_ctx.cursor_bindings[]
    cbs = cursor_bindings(comp_ctx.st0_top, comp_ctx.offset, comp_ctx.context_module;
        soft_scope=comp_ctx.soft_scope)
    return comp_ctx.cursor_bindings[] = cbs
end

# Typical completion UI
# =====================

# `to|` ->
# ```
#    ┌───┬──────────────────────────┬────────────────────────────┐
#    │(1)│to_completion(2)     (3) >│(4)...                      │
#    │(1)│to_indices(2)        (3)  │# Typical completion UI ─(5)│
#    │(1)│touch(2)             (3)  │                          │ │
#    └───┴──────────────────────────┤to|                       │ │
#                                   │...                     ──┘ │
#                                   └────────────────────────────┘
# ```
# - (1) Icon corresponding to CompletionItem's `ci.kind`
# - (2) `ci.labelDetails.detail`
# - (3) `ci.labelDetails.description`
# - (4) `ci.detail` (possibly at (3))
# - (5) `ci.documentation`
#
# Sending (4) and (5) to the client can happen eagerly in response to <TAB>
# (textDocument/completion), or lazily, on selection in the list
# (completionItem/resolve).  The LSP specification notes that more can be deferred
# in later versions.

# local completions
# =================

function to_completion(
        binding::JL.BindingInfo, st::SyntaxTreeC, sort_offset::Int,
        uri::URI, fi::FileInfo
    )
    label_kind = CompletionItemKind.Variable
    label_detail = label_desc = nothing

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

    typeid = binding.type
    if !isnothing(typeid)
        label_detail = "::" * JS.sourcetext(SyntaxTreeC(JS.syntax_graph(st), typeid))
    end

    io = IOBuffer()
    println(io, "``````julia")
    JL.showprov(io, st; include_location=false)
    println(io)
    println(io, "``````")
    (; line, character) = jsobj_to_range(st, fi).start
    line += 1; character += 1
    showtext = "`@ " * simple_loc_text(uri; line) * "`"
    println(io, create_source_location_link(uri, showtext; line, character))
    value = String(take!(io))
    documentation = MarkupContent(; kind = MarkupKind.Markdown, value)

    CompletionItem(;
        label = binding.name,
        labelDetails = CompletionItemLabelDetails(;
            detail = label_detail,
            description = label_desc),
        kind = label_kind,
        documentation,
        sortText = get_sort_text(sort_offset))
end

# Returns `true` when the request was explicitly invoked
# (`Ctrl+Space`-style), or when it was auto-triggered by a character the
# caller has opted into (`@` for macros, `.` for property/module-member).
# Numeric / whitespace trigger characters etc. don't fire auto-completion.
function should_invoke_auto_completion(context::CompletionContext;
        allow_macro::Bool=false, allow_dot::Bool=false)
    context.triggerKind == CompletionTriggerKind.Invoked && return true
    allow_macro && context.triggerCharacter == "@" && return true
    allow_dot && context.triggerCharacter == "." && return true
    return false
end
should_invoke_auto_completion(::Nothing; _kwargs...) = true

function local_completions!(
        items::Dict{String,CompletionItem}, comp_ctx::CompletionCtx,
    )
    should_invoke_auto_completion(comp_ctx.context) || return nothing

    # NOTE don't bail out even if `length(fi.parsed_stream.diagnostics) ≠ 0`
    # so that we can get some completions even for incomplete code
    cbs = @something get_cursor_bindings_cached!(comp_ctx) return nothing
    for (bi, st, dist) in cbs
        ci = to_completion(bi, st, dist, comp_ctx.uri, comp_ctx.fi)
        prev_ci = get(items, ci.label, nothing)
        # Name collisions: overrule existing global completions with our own,
        # unless our completion is also a global, in which case the existing
        # completion from JET will have more information.
        if isnothing(prev_ci) || (completion_is(prev_ci, :global) && !completion_is(ci, :global))
            items[ci.label] = ci
        end
    end
    return nothing
end

# global completions
# ==================

function global_completions!(
        items::Dict{String,CompletionItem}, comp_ctx::CompletionCtx,
    )
    (; state, uri, fi, pos, context, st0_top, world, postprocessor) = comp_ctx
    context_module = comp_ctx.context_module
    should_invoke_auto_completion(context; allow_macro=true, allow_dot=true) || return nothing

    prev_token = token_before_offset(fi, pos)
    prev_kind = isnothing(prev_token) ? nothing : JS.kind(prev_token)

    # Case: `@│`
    if prev_kind === JS.K"@"
        edit_start_pos = offset_to_xy(fi, JS.first_byte(prev_token))
        is_macro_invoke = true
    # Case `│` (empty program)
    elseif isnothing(prev_token)
        edit_start_pos = Position(; line=0, character=0)
        is_macro_invoke = false
    elseif JS.is_identifier(prev_kind)
        pprev_token = prev_tok(prev_token)
        if !isnothing(pprev_token) && JS.kind(pprev_token) === JS.K"@"
            # Case: `@macr│`
            edit_start_pos = offset_to_xy(fi, JS.first_byte(pprev_token))
            is_macro_invoke = true
        else
            edit_start_pos = offset_to_xy(fi, JS.first_byte(prev_token))
            is_macro_invoke = false
        end
    else
        # When completion is triggered within unknown scope (e.g., comment),
        # it's difficult to properly specify `edit_start_pos`.
        # Simply specify only the `label` and let the client handle it appropriately.
        edit_start_pos = nothing
        is_macro_invoke = false
    end

    # if we are in macro name context, then we don't need the local completions
    # since macros are always defined top-level
    is_completed = is_macro_invoke

    dotprefix = select_dotprefix_identifier(st0_top, comp_ctx.offset)
    if !isnothing(dotprefix)
        rng = JS.byte_range(dotprefix)
        ctx = get_inferred_ctx!(comp_ctx; caller="global_completions!")
        prefixtyp = ctx === nothing ? nothing : get_type_for_range(ctx, rng)
        if prefixtyp === nothing
            prefixtyp = resolve_global_const(context_module, dotprefix, world)
        end
        # Module prefix → enumerate that module's globals below.
        # Otherwise → property completion (abstract-call
        # `propertynames` / `getproperty` on the prefix's type).
        if prefixtyp isa Core.Const && prefixtyp.val isa Module
            context_module = prefixtyp.val::Module
            # disable local completions for dot-prefixed code
            is_completed |= true
        else
            if prefixtyp !== nothing
                prefix = JS.sourcetext(dotprefix)
                add_property_completions!(items, comp_ctx, prefixtyp, prefix)
            end
            return #=isIncomplete=#false
        end
    end
    resolver_id = String(gensym("GlobalCompletionResolverInfo_resovler_id"))
    store!(state.completion_resolver_info, context_module) do _, ctx_mod::Module
        GlobalCompletionResolverInfo(resolver_id, ctx_mod, world, postprocessor), nothing
    end

    prioritized_names = let s = Set{Symbol}()
        pnames = Base.invoke_in_world(
            world, names, context_module; all=true)::Vector{Symbol}
        sizehint!(s, length(pnames))
        for name in pnames
            startswith(String(name), "#") && continue
            push!(s, name)
        end
        s
    end

    all_names = Base.invoke_in_world(world, names, context_module;
        all=true, imported=true, usings=true)::Vector{Symbol}
    for name in all_names
        s = String(name)
        startswith(s, "#") && continue

        startswith_at = startswith(s, "@")

        if is_macro_invoke && !startswith_at
            # If we are in a macro invocation context, we only want to complete macros.
            # Conversely, we allow macros to be completed in any context.
            continue
        end

        resolveName = newText = label = s
        detail = filterText = nothing
        insertTextFormat = InsertTextFormat.PlainText
        if startswith_at
            if endswith(s, "_str")
                detail = "[string macro]"
                strname = replace(lstrip(s, '@'), r"_str$" => "")
                label = strname * "\"\""
                if supports(state, :textDocument, :completion, :completionItem, :snippetSupport)
                    newText = strname * "\"\${1:str}\"\$0" # ${0:flags}?
                    insertTextFormat = InsertTextFormat.Snippet
                else
                    newText = label
                end
                filterText = strname
                resolveName = s
            else
                detail = "[macro]"
            end
        end
        if name in prioritized_names
            sortText = max_sort_text1
        else
            sortText = max_sort_text2
        end
        textEdit = if isnothing(edit_start_pos)
            nothing
        else
            range, _ = unadjust_range(state, uri, Range(;
                start = edit_start_pos,
                var"end" = pos))
            TextEdit(; range, newText)
        end

        labelDetails = CompletionItemLabelDetails(; description = "global")

        # N.B. Don't set `kind` here to prevent Zed from applying highlights to the `label` at this stage.
        # The determination of `kind` involves reflection such as `getglobal`, so it is lazily resolved (see `resolve_completion_item`)
        items[s] = CompletionItem(;
            label,
            labelDetails,
            detail,
            sortText,
            filterText,
            insertTextFormat,
            textEdit,
            data = GlobalCompletionData(resolver_id, resolveName))
    end

    return is_completed ? #=isIncomplete=#false : nothing
end

# Property completions
# ====================

# Try property completion for `prefix.│` / `prefix.partial│`. Asks inference
# what `propertynames(::T)` returns for the dot prefix's inferred type `T`;
# if that's a `Core.Const(::Tuple{Vararg{Symbol}})`, those are the property
# names. This subsumes both the default `fieldnames` path and `propertynames`
# overrides (e.g. `Regex` returning `(:pattern, :compile_options, …)`) —
# inference handles both uniformly.
#
# Each name's type detail (`getproperty(::T, Core.Const(:name))`) is deferred
# to `resolve_property_completion_item` so the abstract-call only fires for
# the property the user actually focuses, not all of them up front.
function add_property_completions!(
        items::Dict{String,CompletionItem}, comp_ctx::CompletionCtx,
        @nospecialize(prefixtyp), prefix::AbstractString
    )
    # Union of `propertynames(::T)` across union components. Intersection would be safer in
    # theory ("only properties available on every side"), but it falls flat on the very
    # common `Union{T, Nothing}` case — `propertynames(::Nothing)` is empty, so the
    # intersection vanishes. Names that exist only on a subset of components are kept;
    # if the user accesses one when the value happens to be the other side it'll error
    # at runtime, which is the same trade-off Julia itself accepts.
    #
    # `ordered` preserves source declaration order (each component's `propertynames` is
    # appended in its own order, with `seen` dropping duplicates), so the `sortText` below
    # renders the completion list in the order the user wrote the fields.
    ordered = Symbol[]
    seen = Set{Symbol}()
    for typ in union_components(prefixtyp)
        rt = abstract_call_const(propertynames, Any[typ], comp_ctx.world)
        rt isa Core.Const || continue
        names = rt.val
        names isa Tuple{Vararg{Symbol}} || continue
        for n in names
            n in seen && continue
            push!(seen, n)
            push!(ordered, n)
        end
    end
    isempty(ordered) && return false

    resolver_id = String(gensym("PropertyCompletionResolverInfo_resovler_id"))
    store!(comp_ctx.state.completion_resolver_info) do _
        resolver_info = PropertyCompletionResolverInfo(
            resolver_id, prefixtyp, comp_ctx.world, comp_ctx.postprocessor)
        resolver_info, nothing
    end

    for (i, name) in enumerate(ordered)
        label = String(name)
        items[label] = CompletionItem(;
            label,
            labelDetails = CompletionItemLabelDetails(; description = "property"),
            kind = CompletionItemKind.Property,
            sortText = get_sort_text(i),
            data = PropertyCompletionData(resolver_id, label, prefix))
    end
    return true
end

function union_components(@nospecialize(prefixtyp))
    typ = CC.widenconst(prefixtyp)
    return typ isa Union ? Base.uniontypes(typ) : Any[typ]
end

# LaTeX and emoji completions
# ===========================

"""
    get_backslash_offset(fi::FileInfo, pos::Position) -> offset::Int, is_emoji::Bool

Get the byte `offset` of a backslash if the token immediately before the cursor
consists of a backslash and colon.
`is_emoji` indicates that a backslash is followed by the emoji completion trigger (`:`).
Returns `nothing` if such a token does not exist or if another token appears
immediately before the cursor.

Examples:
0. `┃...`           returns `nothing`
1. `\\┃ beta`       returns byte offset of `\\` and `false`
2. `\\alph┃`        returns byte offset of `\\` and `false`
3. `\\  ┃`          returns `nothing` (whitespace before cursor)
4. `\\:┃`           returns byte offset of `\\` and `true`
5. `\\:smile┃       returns byte offset of `\\` and `true`
6. `\\:+1┃          returns byte offset of `\\` and `true`
7. `alpha┃`         returns `nothing`  (no backslash before cursor)
8. `\\alpha  bet┃a` returns `nothing` (no backslash immediately before token with cursor)
9. `# \\┃`          returns byte offset of `\\` and `false` or `true` if followed by `:` (comment scope)
"""
function get_backslash_offset(fi::FileInfo, pos::Position)
    # Search backwards from cursor position for backslash
    textbuf = fi.parsed_stream.textbuf
    separators = (UInt8(' '), UInt8('\t'), UInt8('\n'), UInt8('"'), UInt8('\''))
    semicolon = false
    cursor_byte = xy_to_offset(fi, pos)-1
    for i = cursor_byte:-1:1
        c = textbuf[i]
        if c == UInt8(':')
            semicolon = true
        elseif c == UInt8('\\')
            return i, semicolon
        elseif c in separators
            break
        else
            semicolon = false
        end
    end
end

# Add LaTeX and emoji completions to the items dictionary and return boolean indicating
# whether any completions were added.
function add_emoji_latex_completions!(
        items::Dict{String,CompletionItem}, comp_ctx::CompletionCtx,
    )
    (; state, uri, fi, pos) = comp_ctx
    backslash_offset, emojionly = @something get_backslash_offset(fi, pos) return nothing
    backslash_pos = offset_to_xy(fi, backslash_offset)
    edit_range, _ = unadjust_range(state, uri, Range(;
        start = backslash_pos,
        var"end" = pos))

    # HACK Some clients (e.g., Zed) don't properly use `sortText` for completion items
    # containing `\\` or `:`, falling back to `label`-based sorting. For these clients,
    # we strip `\\` and `:` from `label` so sorting works correctly.
    # Other clients (e.g., VSCode) properly handles `\` character appearing in `sortText`,
    # so we keep `label` as-is.
    strip_prefix = @somereal(
        get_config(state, :completion, :latex_emoji, :strip_prefix),
        # auto-detect based on client
        getobjpath(state, :init_params, :clientInfo, :name) ∈ ("Zed", "Zed Dev"))

    create_ci = function (key, val, is_emoji::Bool)
        description = is_emoji ? "emoji" : "latex-symbol"
        helpText = strip_prefix ? rstrip(lstrip(lstrip(key, '\\'), ':'), ':') : key
        return CompletionItem(;
            label = helpText,
            labelDetails = CompletionItemLabelDetails(;
                description),
            kind = CompletionItemKind.Snippet,
            documentation = val,
            sortText = helpText,
            filterText = helpText,
            textEdit = TextEdit(;
                range = edit_range,
                newText = val))
    end

    emojionly || foreach(REPL.REPLCompletions.latex_symbols) do (key, val)
        items[key] = create_ci(key, val, false)
    end
    foreach(REPL.REPLCompletions.emoji_symbols) do (key, val)
        items[key] = create_ci(key, val, true)
    end

    # if we reached here, we have added all emoji and latex completions
    return #=isIncomplete=#false
end

# keyword completions
# ===================

function get_keyword_doc(kwname::Symbol)
    if kwname in (Symbol("true"), Symbol("false"))
        return MarkupContent(;
            kind = MarkupKind.Markdown,
            value = string(@doc true))
    end
    kwdocstr = Base.Docs.keywords[kwname]
    kwdocobj = kwdocstr.object
    if kwdocobj isa Markdown.MD
        docmd = kwdocobj
    else
        docmd = Markdown.parse(kwdocstr.text[1])
    end
    return MarkupContent(;
        kind = MarkupKind.Markdown,
        value = string(docmd))
end

const KEYWORD_COMPLETIONS = Dict{String,CompletionItem}()
const KEYWORD_DOCS = Dict{String,MarkupContent}()
let keywords = Set{String}()
    union!(keywords, REPL.REPLCompletions.sorted_keywords, REPL.REPLCompletions.sorted_keyvals)
    for keyword in keywords
        documentation = get_keyword_doc(Symbol(keyword))
        KEYWORD_COMPLETIONS[keyword] = CompletionItem(;
            label = keyword,
            labelDetails = CompletionItemLabelDetails(; description = "keyword"),
            kind = CompletionItemKind.Keyword,
            sortText = max_sort_text3,
            documentation)
    end
    for keyword in keys(Base.Docs.keywords)
        KEYWORD_DOCS[String(keyword)] = get_keyword_doc(keyword)
    end
end

const var_quote_doc = get_keyword_doc(Symbol("var\"name\""))

function keyword_completions!(
        items::Dict{String,CompletionItem}, comp_ctx::CompletionCtx,
    )
    (; state, context) = comp_ctx
    should_invoke_auto_completion(context) || return nothing

    merge!(items, KEYWORD_COMPLETIONS)
    if supports(state, :textDocument, :completion, :completionItem, :snippetSupport)
        items["var\"\""] = CompletionItem(;
            label = "var\"\"",
            labelDetails = CompletionItemLabelDetails(; description = "keyword"),
            kind = CompletionItemKind.Keyword,
            sortText = max_sort_text3,
            insertText = "var\"\${1:name}\"\$0",
            insertTextFormat = InsertTextFormat.Snippet,
            documentation = var_quote_doc)
    else
        items["var\"\""] = CompletionItem(;
            label = "var\"\"",
            labelDetails = CompletionItemLabelDetails(; description = "keyword"),
            kind = CompletionItemKind.Keyword,
            sortText = max_sort_text3,
            documentation = var_quote_doc)
    end
    return nothing
end

# call completions (method signatures and keyword arguments)
# ==========================================================

function extract_param_text(p::SyntaxTreeC)
     k = JS.kind(p)
    if k === JS.K"Identifier"
        return extract_name_val(p)
    elseif k === JS.K"::"
        n = JS.numchildren(p)
        if n == 1
            typ = JS.sourcetext(p[1])
            return String("::" * typ)
        elseif n == 2
            name = @something extract_param_text(p[1]) return nothing
            typ = JS.sourcetext(p[2])
            return String(name * "::" * typ)
        else
            return nothing
        end
    elseif k === JS.K"var" && JS.numchildren(p) == 1
        inner = p[1]
        if JS.kind(inner) === JS.K"Identifier"
            return extract_name_val(inner)
        end
    end
    return nothing
end

escape_snippet_text(s::AbstractString) =
    replace(s, '\\' => "\\\\", '$' => "\\\$", '}' => "\\}")

function make_insert_text(msig::AbstractString, num_existing_args::Int, use_snippet::Bool)
    mnode = JS.parsestmt(JS.SyntaxTree, msig; ignore_errors=true)
    mnode = unwrap_funcdef_sig(mnode)
    JS.kind(mnode) in CALL_KINDS || return nothing
    params, kwp_i, _ = flatten_args(mnode)
    pos_params_count = kwp_i - 1
    remaining_start = num_existing_args + 1
    remaining_start > pos_params_count && return nothing
    parts = String[]
    snippet_idx = 1
    for i in remaining_start:pos_params_count
        p = params[i]
        k = JS.kind(p)
        k in JS.KSet"= kw" && continue
        if k === JS.K"..." && JS.numchildren(p) ≥ 1
            inner = p[1]
            text = extract_param_text(inner)
            isnothing(text) && continue
            text = text * "..."
        else
            text = extract_param_text(p)
            isnothing(text) && continue
        end
        if use_snippet
            push!(parts, "\${$(snippet_idx):$(escape_snippet_text(text))}")
            snippet_idx += 1
        else
            push!(parts, text)
        end
    end
    isempty(parts) && return nothing
    return join(parts, ", ")
end

function cursor_equals_position(ca::CallArgs, b::Int)
    for arg in ca.args
        br = JS.byte_range(arg)
        first(br) ≤ b ≤ last(br) + 1 || continue
        JS.kind(arg) in JS.KSet"= kw" || return nothing
        JS.numchildren(arg) ≥ 2 || return nothing
        rhs = arg[2]
        after_equals = if JS.kind(rhs) === JS.K"error"
            lhs_end = JS.last_byte(arg[1])
            b > lhs_end + 1
        else
            b ≥ JS.first_byte(rhs)
        end
        return after_equals
    end
    return nothing
end

function extract_kwarg_name_str(p::SyntaxTreeC)
    node = @something extract_kwarg_name(p; sig=true) return nothing
    return extract_name_val(node)
end

function should_insert_spaces_around_equal(fi::FileInfo, ca::CallArgs)
    has_whitespaces = has_equals = 0
    for i in values(ca.kw_map)
        kwnode = ca.args[i]
        JS.kind(kwnode) === JS.K"kw" || continue
        has_equals += 1
        pos = offset_to_xy(fi, JS.first_byte(kwnode))
        tok = @something token_at_offset(fi, pos) continue
        while JS.is_whitespace(this(tok))
            tok = @something next_tok(tok) @goto next
        end
        JS.kind(this(tok)) === JS.K"Identifier" || continue
        tok = @something next_tok(tok) continue
        JS.is_whitespace(this(tok)) || continue
        tok = @something next_tok(tok) continue
        JS.is_plain_equals(this(tok)) || continue
        tok = @something next_tok(tok) continue
        JS.is_whitespace(this(tok)) || continue
        has_whitespaces += 1
        @label next
    end
    return has_whitespaces ≥ has_equals - has_whitespaces
end

function call_completions!(
        items::Dict{String,CompletionItem}, comp_ctx::CompletionCtx,
    )
    (; state, fi, pos, context, st0_top, context_module, world, postprocessor) = comp_ctx
    b = comp_ctx.offset
    call = @something cursor_call(fi.parsed_stream, st0_top, b) return nothing
    ca = CallArgs(call, b)

    equals_pos = cursor_equals_position(ca, b)
    should_complete_method_sigs = !ca.has_semicolon && !isnothing(context) &&
        context.triggerCharacter ∈ METHOD_COMPLETION_TRIGGER_CHARACTERS
    should_complete_kwargs = !(equals_pos === true) # is not after `=`

    should_complete_method_sigs || should_complete_kwargs || return nothing

    ctx = get_inferred_ctx!(comp_ctx; caller="call_completions!")
    fntyp = ctx === nothing ? nothing : get_type_for_range(ctx, JS.byte_range(call[1]))
    if fntyp === nothing
        fntyp = resolve_global_const(context_module, call[1], world)
    end
    fntyp isa Core.Const || return nothing

    argtypes = @something collect_call_argtypes(ctx, ca) return nothing
    fixup_argtypes!(argtypes, fntyp)
    matches = @something find_all_matches(argtypes; world) return nothing
    isempty(matches) && return nothing

    num_existing_args = ca.kw_i - 1
    has_equals = equals_pos === false
    local method_sig_comp_info, kwarg_comp_info
    if should_complete_method_sigs
        local resolver_id = String(gensym("MethodSignatureCompletionResolverInfo_resovler_id"))
        store!(state.completion_resolver_info) do _
            MethodSignatureCompletionResolverInfo(resolver_id, world, matches, postprocessor), nothing
        end
        method_sig_comp_info = (;
            resolver_id,
            use_snippet = supports(state, :textDocument, :completion, :completionItem, :snippetSupport))
    else
        @assert should_complete_kwargs
        kwarg_comp_info = (;
            existing_kws = Set{String}(keys(ca.kw_map)),
            seen_kwarg_names = Set{String}(),
            insert_spaces = should_insert_spaces_around_equal(fi, ca),
            local_bindings = has_equals ? nothing : get_cursor_bindings_cached!(comp_ctx))
    end

    method_sig_sort_idx = 1
    for (i, match) in enumerate(matches)
        m = match.method
        startswith(String(m.name), '@') && continue
        compatible_method(m, ca, world) || continue
        msig = @something get_sig_str(m, ca, world) continue

        if @isdefined(method_sig_comp_info) # i.e. should_complete_method_sigs
            local (; resolver_id, use_snippet) = method_sig_comp_info
            msig_label = postprocessor(msig)
            base_text = make_insert_text(msig_label, num_existing_args, use_snippet)
            newText = if isnothing(base_text)
                ""
            else
                prefix = (num_existing_args > 0 && context.triggerCharacter == ",") ? " " : ""
                prefix * base_text
            end
            label = String(msig_label)
            items[label] = CompletionItem(;
                label,
                labelDetails = CompletionItemLabelDetails(; description = "method"),
                kind = CompletionItemKind.Method,
                textEdit = TextEdit(; range=Range(pos, pos), newText),
                insertTextFormat = use_snippet ? InsertTextFormat.Snippet : InsertTextFormat.PlainText,
                sortText = get_sort_text(method_sig_sort_idx),
                data = MethodSignatureCompletionData(resolver_id, i),
            )
            method_sig_sort_idx += 1
        elseif @isdefined(kwarg_comp_info) # i.e. should_complete_kwargs
            (; existing_kws, seen_kwarg_names, insert_spaces, local_bindings) = kwarg_comp_info
            mnode = JS.parsestmt(JS.SyntaxTree, msig; ignore_errors=true)
            mnode = unwrap_funcdef_sig(mnode)
            JS.kind(mnode) in CALL_KINDS || continue
            params, kwp_i, has_semicolon = flatten_args(mnode)
            kwname_sort_idx = 1
            for j in kwp_i:lastindex(params)
                p = params[j]
                JS.kind(p) === JS.K"..." && continue
                kwarg_name = @something extract_kwarg_name_str(p) continue
                kwarg_name in existing_kws && continue
                kwarg_name in seen_kwarg_names && continue
                push!(seen_kwarg_names, kwarg_name)
                if has_equals
                    suffix = ""
                else
                    local_var_existing = !isnothing(local_bindings) &&
                        any(((binding,_,_),)->binding.name==kwarg_name, local_bindings)
                    if local_var_existing
                        suffix = ""
                    else
                        suffix = insert_spaces ? " = " : "="
                    end
                end
                items[kwarg_name] = CompletionItem(;
                    label = kwarg_name,
                    labelDetails = CompletionItemLabelDetails(; description = "keyword argument"),
                    insertText = kwarg_name * suffix,
                    sortText = has_semicolon ? get_sort_text(kwname_sort_idx) : max_sort_text1,
                )
                kwname_sort_idx += 1
            end
        else error("Unreachable") end
    end
    if should_complete_kwargs && ca.has_semicolon
        return #=isIncomplete=#false
    elseif should_complete_method_sigs && method_sig_sort_idx > 1
        return #=isIncomplete=#true
    end
    return nothing
end

# completion resolver
# ===================

function lookup_doc_for_match(match::Core.MethodMatch, world::UInt)
    m = match.method
    Base.invoke_in_world(world, isdefinedglobal, m.module, m.name) || return nothing
    mfunc = Base.invoke_in_world(world, getglobal, m.module, m.name)
    sig = @something method_doc_sig(m) return nothing
    return lookup_doc_for_value(mfunc, sig, world)
end

const builtin_functions = Core.Builtin[getglobal(Core, n) for n in names(Core) if getglobal(Core, n) isa Core.Builtin]
const builtin_types = Type[getglobal(Core, n) for n in names(Core) if getglobal(Core, n) isa Type]

# Spec quirks around lazy-resolvable properties (see aviatesk/JETLS.jl#711):
# - 3.16.0+ with `resolveSupport.properties` declared: the list is exhaustive —
#   any property not in it cannot be resolved lazily (the resolved value is
#   silently dropped or even mis-rendered).
# - Pre-3.16.0 (no `resolveSupport`): only `documentation` and `detail` are
#   lazy-resolvable. We honor this for backward compatibility.
function supports_completion_item_resolve(state::ServerState, property::AbstractString)
    if getobjpath(state, :init_params, :clientInfo, :name) ∈ ("Zed", "Zed Dev")
        # Special case: Zed under-declares `resolveSupport` but actually applies lazy
        # updates for every non-`label` field, so opt it into the full set unconditionally.
        return true
    end
    properties = getcapability(state, :textDocument, :completion, :completionItem,
        :resolveSupport, :properties)
    if properties !== nothing
        return property in properties
    end
    return property in ("documentation", "detail")
end

function resolve_completion_item(state::ServerState, item::CompletionItem)
    completion_resolver_info = @something load(state.completion_resolver_info) return item
    data = item.data
    if (data isa GlobalCompletionData &&
        completion_resolver_info isa GlobalCompletionResolverInfo &&
        data.resolver_id == completion_resolver_info.id)
        return resolve_global_completion_item(state, item, data, completion_resolver_info)
    elseif (data isa MethodSignatureCompletionData &&
            completion_resolver_info isa MethodSignatureCompletionResolverInfo &&
            data.resolver_id == completion_resolver_info.id)
        return resolve_method_signature_completion_item(state, item, data, completion_resolver_info)
    elseif (data isa PropertyCompletionData &&
            completion_resolver_info isa PropertyCompletionResolverInfo &&
            data.resolver_id == completion_resolver_info.id)
        return resolve_property_completion_item(state, item, data, completion_resolver_info)
    else
        return item
    end
end

function resolve_property_completion_item(
        state::ServerState, item::CompletionItem, data::PropertyCompletionData,
        completion_resolver_info::PropertyCompletionResolverInfo,
    )
    supports_labelDetails = supports_completion_item_resolve(state, "labelDetails")
    supports_detail = supports_completion_item_resolve(state, "detail")
    supports_documentation = supports_completion_item_resolve(state, "documentation")
    supports_labelDetails || supports_detail || supports_documentation || return item

    (; prefixtyp, world, postprocessor) = completion_resolver_info

    # `Union` (tmerge) the per-component `getproperty(::T, Core.Const(name))` result, so a
    # `Union{Foo, Bar}` prefix shows the union of field types rather than just one side's.
    name = Core.Const(Symbol(data.label))
    rawtyp = Union{}
    for comp in union_components(prefixtyp)
        gp_rt = @something abstract_call_const(getproperty, Any[comp, name], world) continue
        rawtyp = CC.tmerge(rawtyp, gp_rt)
    end
    typstr = truncate_typstr(
        postprocessor(sprint(show, rawtyp; context = :compact => true)),
        #=maxdepth=#3, #=maxwidth=#20)
    detail = " ::" * typstr
    full_typstr = postprocessor(string(rawtyp))
    io = IOBuffer()
    print(io, "```julia\n", data.prefix, ".", data.label, " :: ", full_typstr, "\n```")
    fdoc = lookup_field_doc(prefixtyp, Symbol(data.label), world)
    if fdoc isa Markdown.MD
        print(io, "\n\n---\n\n", postprocessor(fdoc))
    end
    value = String(take!(io))

    labelDetails = supports_labelDetails ?
        CompletionItemLabelDetails(; detail, description = "property") : item.labelDetails
    detail = supports_detail ? detail : item.detail
    documentation = supports_documentation ?
        MarkupContent(; kind = MarkupKind.Markdown, value) : item.documentation
    return CompletionItem(item; labelDetails, detail, documentation)
end

function resolve_global_completion_item(
        state::ServerState, item::CompletionItem, data::GlobalCompletionData,
        completion_resolver_info::GlobalCompletionResolverInfo
    )
    supports_labelDetails = supports_completion_item_resolve(state, "labelDetails")
    supports_kind = supports_completion_item_resolve(state, "kind")
    supports_detail = supports_completion_item_resolve(state, "detail")
    supports_documentation = supports_completion_item_resolve(state, "documentation")
    supports_labelDetails || supports_kind || supports_detail || supports_documentation || return item

    (; context_module, world, postprocessor) = completion_resolver_info
    name = Symbol(data.name)
    docs = postprocessor(Base.invoke_in_world(world,
        Base.Docs.doc, Base.Docs.Binding(context_module, name))::Markdown.MD)
    (; labelDetails, detail) = item
    # This `kind` doesn't have much meaning in itself, but at least by setting `kind`,
    # we enable tree-sitter-based highlighting of the `label` in zed-julia
    kind = CompletionItemKind.Snippet
    if isnothing(detail) || isnothing(kind)
        if Base.invoke_in_world(world, isdefinedglobal, context_module, name)::Bool
            obj = Base.invoke_in_world(world, getglobal, context_module, name)
            if obj isa Type
                if obj in builtin_types
                    detail = "[builtin type]"
                    kind = CompletionItemKind.Constant
                else
                    detail = "[type]"
                    kind = CompletionItemKind.Struct
                end
            elseif obj isa Function
                if obj isa Core.Builtin && obj in builtin_functions
                    detail = "[builtin function]"
                    kind = CompletionItemKind.Constant
                else
                    detail = "[function]"
                    kind = CompletionItemKind.Function
                end
            elseif obj isa Module
                detail = "[module]"
                kind = CompletionItemKind.Module
            elseif Base.invoke_in_world(world, isconst, context_module, name)
                detail = "[constant variable]"
                kind = CompletionItemKind.Constant
            else
                detail = "[variable]"
                kind = CompletionItemKind.Variable
            end
        end
    end

    if !isnothing(detail) && supports_labelDetails
        labelDetails = CompletionItemLabelDetails(; description = "global " * detail)
    end
    supports_kind || (kind = item.kind)
    supports_detail || (detail = item.detail)
    documentation = supports_documentation ?
        MarkupContent(; kind = MarkupKind.Markdown, value = docs) : item.documentation

    return CompletionItem(item; labelDetails, kind, detail, documentation)
end

function resolve_method_signature_completion_item(
        state::ServerState, item::CompletionItem, data::MethodSignatureCompletionData,
        completion_resolver_info::MethodSignatureCompletionResolverInfo
    )
    supports_labelDetails = supports_completion_item_resolve(state, "labelDetails")
    supports_detail = supports_completion_item_resolve(state, "detail")
    supports_documentation = supports_completion_item_resolve(state, "documentation")
    supports_labelDetails || supports_detail || supports_documentation || return item

    (; world, matches, postprocessor) = completion_resolver_info
    1 ≤ data.match_idx ≤ length(matches) || return item # just to make sure
    match = matches[data.match_idx]
    doc = @something lookup_doc_for_match(match, world) return item
    docstr = postprocessor(string(doc))
    _, result = infer_match!(world, match)
    resulttyp = @something result.result return item
    rettyp = CC.widenconst(resulttyp)
    # TODO Show effects and exception type?
    typstr = truncate_typstr(
        postprocessor(sprint(show, rettyp; context = :compact => true)),
        #=maxdepth=#3, #=maxwidth=#20)
    detail = " -> " * typstr
    full_typstr = postprocessor(string(rettyp))
    value = """
    ```julia
    $(item.label) -> $(full_typstr)
    ```
    ---
    """ * docstr

    labelDetails = supports_labelDetails ?
        CompletionItemLabelDetails(; detail, description = "method") : item.labelDetails
    detail = supports_detail ? detail : item.detail
    documentation = supports_documentation ?
        MarkupContent(; kind = MarkupKind.Markdown, value) : item.documentation

    return CompletionItem(item; labelDetails, detail, documentation)
end

# request handler
# ===============

function get_completion_items(
        state::ServerState, uri::URI, fi::FileInfo,
        pos::Position, context::Union{Nothing,CompletionContext};
        context_module::Union{Nothing,Module} = nothing,
    )
    comp_ctx = CompletionCtx(state, uri, fi, pos, context; context_module)
    items = Dict{String,CompletionItem}()
    # order matters; see local_completions!
    isIncomplete = @something(
        add_emoji_latex_completions!(items, comp_ctx),
        call_completions!(items, comp_ctx),
        global_completions!(items, comp_ctx),
        local_completions!(items, comp_ctx),
        keyword_completions!(items, comp_ctx),
        false)
    return collect(values(items)), isIncomplete
end

function handle_CompletionRequest(
        server::Server, msg::CompletionRequest, cancel_flag::CancelFlag)
    state = server.state
    uri = msg.params.textDocument.uri
    result = get_file_info(state, uri, cancel_flag)
    if isnothing(result)
        return send(server, CompletionResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, CompletionResponse(; id = msg.id, result = nothing, error = result))
    end
    fi = result
    pos = adjust_position(state, uri, msg.params.position)
    items, isIncomplete = get_completion_items(state, uri, fi, pos, msg.params.context)
    # For method signature completions, set `isIncomplete = true` so that when
    # the user continues typing (e.g., an identifier), the client will re-request
    # and trigger global/local completions instead of continuing to filter
    # method signatures.
    return send(server,
        CompletionResponse(;
            id = msg.id,
            result = CompletionList(; isIncomplete, items)))
end

function handle_CompletionResolveRequest(server::Server, msg::CompletionResolveRequest)
    return send(server,
        CompletionResolveResponse(;
            id = msg.id,
            result = resolve_completion_item(server.state, msg.params)))
end
