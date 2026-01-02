# initialization
# ==============

const NUMERIC_CHARACTERS = tuple(string.('0':'9')...)
const COMPLETION_TRIGGER_CHARACTERS = [
    "@",  # macro completion
    "\\", # LaTeX completion
    ":",  # emoji completion
    ";",  # keyword argument completion
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

# local completions
# =================

"""
# Typical completion UI

`to|` ->
```
   ┌───┬──────────────────────────┬────────────────────────────┐
   │(1)│to_completion(2)     (3) >│(4)...                      │
   │(1)│to_indices(2)        (3)  │# Typical completion UI ─(5)│
   │(1)│touch(2)             (3)  │                          │ │
   └───┴──────────────────────────┤to|                       │ │
                                  │...                     ──┘ │
                                  └────────────────────────────┘
```
- (1) Icon corresponding to CompletionItem's `ci.kind`
- (2) `ci.labelDetails.detail`
- (3) `ci.labelDetails.description`
- (4) `ci.detail` (possibly at (3))
- (5) `ci.documentation`

Sending (4) and (5) to the client can happen eagerly in response to <TAB>
(textDocument/completion), or lazily, on selection in the list
(completionItem/resolve).  The LSP specification notes that more can be deferred
in later versions.
"""
function to_completion(
        binding::JL.BindingInfo, st::JL.SyntaxTree, sort_offset::Int,
        uri::URI, fi::FileInfo
    )
    label_kind = CompletionItemKind.Variable
    label_detail = nothing
    label_desc = nothing
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
    documentation = MarkupContent(;
        kind = MarkupKind.Markdown,
        value)

    CompletionItem(;
        label = binding.name,
        labelDetails = CompletionItemLabelDetails(;
            detail = label_detail,
            description = label_desc),
        kind = label_kind,
        documentation,
        sortText = get_sort_text(sort_offset))
end

should_invoke_auto_completion(::Nothing, ::Bool=false) = true
function should_invoke_auto_completion(context::CompletionContext, allow_macro::Bool=false)
    if !allow_macro || context.triggerCharacter != "@"
        # Don't trigger completion just by typing a numeric character, etc.
        if context.triggerKind != CompletionTriggerKind.Invoked
            return false
        end
    end
    return true
end

function local_completions!(
        items::Dict{String,CompletionItem},
        s::ServerState, uri::URI, fi::FileInfo, pos::Position, context::Union{Nothing,CompletionContext}
    )
    should_invoke_auto_completion(context) || return nothing

    # NOTE don't bail out even if `length(fi.parsed_stream.diagnostics) ≠ 0`
    # so that we can get some completions even for incomplete code
    st0 = build_syntax_tree(fi)
    (; mod) = get_context_info(s, uri, pos)
    cbs = @something cursor_bindings(st0, xy_to_offset(fi, pos), mod) return nothing
    for (bi, st, dist) in cbs
        ci = to_completion(bi, st, dist, uri, fi)
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
        items::Dict{String,CompletionItem},
        state::ServerState, uri::URI, fi::FileInfo, pos::Position, context::Union{Nothing,CompletionContext},
    )
    should_invoke_auto_completion(context, #=allow_macro=#true) || return nothing

    (; mod, analyzer, postprocessor) = get_context_info(state, uri, pos)
    completion_module = mod

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

    st = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)
    dotprefix = select_dotprefix_identifier(st, offset)
    if !isnothing(dotprefix)
        prefixtyp = resolve_type(analyzer, completion_module, dotprefix)
        # If dotprefix is not a module, cancel completion entirely.
        # TODO In the future, let's add property completions and such.
        enable_completions = false
        if prefixtyp isa Core.Const
            prefixval = prefixtyp.val
            if prefixval isa Module
                completion_module = prefixval
                enable_completions = true
            end
        end
        enable_completions || return items
        # disable local completions for dot-prefixed code for now
        is_completed |= true
    end
    store!(state.completion_resolver_info) do _
        (completion_module, postprocessor), nothing
    end

    prioritized_names = let s = Set{Symbol}()
        pnames = @invokelatest(names(completion_module; all=true))::Vector{Symbol}
        sizehint!(s, length(pnames))
        for name in pnames
            startswith(String(name), "#") && continue
            push!(s, name)
        end
        s
    end

    for name in @invokelatest(names(completion_module; all=true, imported=true, usings=true))::Vector{Symbol}
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
            data = GlobalCompletionData(resolveName))
    end

    return is_completed ? items : nothing
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
        items::Dict{String,CompletionItem},
        state::ServerState, uri::URI, fi::FileInfo, pos::Position
    )
    backslash_offset, emojionly = @something get_backslash_offset(fi, pos) return nothing
    backslash_pos = offset_to_xy(fi, backslash_offset)
    edit_range, _ = unadjust_range(state, uri, Range(;
        start = backslash_pos,
        var"end" = pos))

    # HACK Certain clients cannot properly sort/filter completion items that contain
    # characters like `\\` or `:`. To help with this, setting `sortText` or `filterText`,
    # or removing `\\` or `:` from the `label`, can cause completion to not trigger
    # in other clients (for example, VSCode falls into this category)...
    # To quickly absorb the differences between each client, we enumerate clients that
    # properly implement `filterText`/`sortText` here, and set `sortText`/`filterText`
    # for those specific clients.
    # TODO This should be configurable in the future.
    use_smart_filter = getobjpath(state, :init_params, :clientInfo, :name) ∉ ("Zed", "Zed Dev")

    function create_ci(key, val, is_emoji::Bool)
        description = is_emoji ? "emoji" : "latex-symbol"
        helpText = use_smart_filter ? nothing : lstrip(lstrip(key, '\\'), ':')
        return CompletionItem(;
            label = key,
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
    return items
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
        items::Dict{String,CompletionItem}, state::ServerState,
        context::Union{Nothing,CompletionContext}
    )
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

# keyword argument completion
# ===========================

function is_after_equals(ca::CallArgs, b::Int)
    for arg in ca.args
        br = JS.byte_range(arg)
        first(br) ≤ b ≤ last(br) + 1 || continue
        JS.kind(arg) in JS.KSet"= kw" || return false
        JS.numchildren(arg) ≥ 1 || return false
        lhs_end = JS.last_byte(arg[1])
        return lhs_end < b
    end
    return false
end

function extract_kwarg_name_str(p::JL.SyntaxTree)
    node = @something extract_kwarg_name(p; sig=true) return nothing
    hasproperty(node, :name_val) || return nothing
    return node.name_val::String
end

function should_insert_spaces_around_equal(fi::FileInfo, ca::CallArgs)
    has_whitespaces = has_equals = 0
    for i in values(ca.kw_map)
        kwnode = ca.args[i]
        JS.kind(kwnode) === JS.K"kw" || continue
        has_equals += 1
        pos = offset_to_xy(fi, JS.first_byte(kwnode))
        tok = token_at_offset(fi, pos)
        while JS.is_whitespace(this(tok))
            tok = next_tok(tok)
        end
        JS.kind(this(tok)) === JS.K"Identifier" || continue
        tok = next_tok(tok)
        JS.is_whitespace(this(tok)) || continue
        tok = next_tok(tok)
        JS.is_plain_equals(this(tok)) || continue
        tok = next_tok(tok)
        JS.is_whitespace(this(tok)) || continue
        has_whitespaces += 1
    end
    return has_whitespaces ≥ has_equals - has_whitespaces
end

function keyword_argument_completions!(
        items::Dict{String,CompletionItem},
        state::ServerState, uri::URI, fi::FileInfo, pos::Position
    )
    st0 = build_syntax_tree(fi)
    b = xy_to_offset(fi, pos)
    call = @something cursor_call(fi.parsed_stream, st0, b) return nothing
    ca = CallArgs(call, b)
    is_after_equals(ca, b) && return nothing

    (; mod, analyzer) = get_context_info(state, uri, pos)
    fntyp = resolve_type(analyzer, mod, call[1])
    fntyp isa Core.Const || return nothing
    candidate_methods = methods(fntyp.val)
    isempty(candidate_methods) && return nothing

    existing_kws = Set{String}(keys(ca.kw_map))
    seen_kwarg_names = Set{String}()
    insert_spaces = should_insert_spaces_around_equal(fi, ca)
    for m in candidate_methods
        startswith(String(m.name), '@') && continue
        compatible_method(m, ca) || continue
        msig = @something get_sig_str(m, ca) continue
        mnode = JS.parsestmt(JL.SyntaxTree, msig; ignore_errors=true)
        while JS.kind(mnode) === JS.K"where" && JS.numchildren(mnode) ≥ 1
            mnode = mnode[1]
        end
        JS.kind(mnode) in CALL_KINDS || continue
        params, kwp_i, _ = flatten_args(mnode)
        for i in kwp_i:lastindex(params)
            p = params[i]
            JS.kind(p) === JS.K"..." && continue
            kwarg_name = @something extract_kwarg_name_str(p) continue
            kwarg_name in existing_kws && continue
            kwarg_name in seen_kwarg_names && continue
            push!(seen_kwarg_names, kwarg_name)
            items[kwarg_name] = CompletionItem(;
                label = kwarg_name,
                labelDetails = CompletionItemLabelDetails(; description = "keyword argument"),
                insertText = kwarg_name * (insert_spaces ? " = " : "="),
                sortText = max_sort_text1, # Give the same prioirty to the (prioritized) global completions
            )
        end
    end
    return ca.has_semicolon ? items : nothing
end

# completion resolver
# ===================

const builtin_functions = Core.Builtin[getglobal(Core, n) for n in names(Core) if getglobal(Core, n) isa Core.Builtin]
const builtin_types = Type[getglobal(Core, n) for n in names(Core) if getglobal(Core, n) isa Type]

function resolve_completion_item(state::ServerState, item::CompletionItem)
    mod, postprocessor = @something load(state.completion_resolver_info) return item
    data = item.data
    if data isa GlobalCompletionData
        name = Symbol(data.name)
        binding = Base.Docs.Binding(mod, name)
        docs = postprocessor(Base.Docs.doc(binding))
        (; labelDetails, detail) = item
        # This `kind` doesn't have much meaning in itself, but at least by setting `kind`,
        # we enable tree-sitter-based highlighting of the `label` in zed-julia
        kind = CompletionItemKind.Snippet
        if isnothing(detail) || isnothing(kind)
            if isdefinedglobal(mod, name)
                obj = getglobal(mod, name)
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
                elseif isconst(mod, name)
                    detail = "[constant variable]"
                    kind = CompletionItemKind.Constant
                else
                    detail = "[variable]"
                    kind = CompletionItemKind.Variable
                end
            end
        end
        if !isnothing(detail)
            labelDetails = CompletionItemLabelDetails(; description = "global " * detail)
        end
        return CompletionItem(item;
            labelDetails, kind, detail,
            documentation = MarkupContent(;
                kind = MarkupKind.Markdown,
                value = docs))
    else
        return item
    end
end

# request handler
# ===============

function get_completion_items(
        state::ServerState, uri::URI, fi::FileInfo,
        pos::Position, context::Union{Nothing,CompletionContext}
    )
    items = Dict{String,CompletionItem}()
    # order matters; see local_completions!
    return collect(values(@something(
        add_emoji_latex_completions!(items, state, uri, fi, pos),
        keyword_argument_completions!(items, state, uri, fi, pos),
        global_completions!(items, state, uri, fi, pos, context),
        local_completions!(items, state, uri, fi, pos, context),
        keyword_completions!(items, state, context),
        items)))
end

function handle_CompletionRequest(
        server::Server, msg::CompletionRequest, cancel_flag::CancelFlag)
    state = server.state
    uri = msg.params.textDocument.uri
    result = get_file_info(state, uri, cancel_flag)
    if result isa ResponseError
        return send(server,
            CompletionResponse(;
                id = msg.id,
                result = nothing,
                error = result))
    end
    fi = result
    pos = adjust_position(state, uri, msg.params.position)
    items = get_completion_items(state, uri, fi, pos, msg.params.context)
    return send(server,
        CompletionResponse(;
            id = msg.id,
            result = CompletionList(;
                isIncomplete = false,
                items)))
end

function handle_CompletionResolveRequest(server::Server, msg::CompletionResolveRequest)
    return send(server,
        CompletionResolveResponse(;
            id = msg.id,
            result = resolve_completion_item(server.state, msg.params)))
end
