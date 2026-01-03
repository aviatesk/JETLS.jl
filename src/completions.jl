# initialization
# ==============

const NUMERIC_CHARACTERS = tuple(string.('0':'9')...)
const METHOD_COMPLETION_TRIGGER_CHARACTERS = ("(", ",", " ")
const COMPLETION_TRIGGER_CHARACTERS = [
    "@",  # macro completion
    "\\", # LaTeX completion
    ":",  # emoji completion
    ";",  # keyword argument completion
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
    label_detail = label_desc = documentation = nothing

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
        enable_completions || return #=isIncomplete=#false
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

    return is_completed ? #=isIncomplete=#false : nothing
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

# call completions (method signatures and keyword arguments)
# ==========================================================

function extract_param_text(p::JL.SyntaxTree)
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
    mnode = JS.parsestmt(JL.SyntaxTree, msig; ignore_errors=true)
    mnode = unwrap_where(mnode)
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

function prepare_method_signature_data(m::Method, methodidx::Int, modules::Vector{Module})
    methodname = String(m.name)
    mod = m.module
    names = String[]
    while true
        pmod = parentmodule(mod)
        pmod == mod && break
        pushfirst!(names, String(nameof(mod)))
        mod = pmod
    end
    moduleidx = @something findfirst(m::Module->m==mod, modules) return nothing
    return MethodSignatureCompletionData(moduleidx, names, methodname, methodidx)
end

function cursor_equals_position(ca::CallArgs, b::Int)::Union{Nothing,Bool}
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

function extract_kwarg_name_str(p::JL.SyntaxTree)
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

function call_completions!(
        items::Dict{String,CompletionItem},
        state::ServerState, uri::URI, fi::FileInfo, pos::Position,
        context::Union{Nothing,CompletionContext}
    )
    st0 = build_syntax_tree(fi)
    b = xy_to_offset(fi, pos)
    call = @something cursor_call(fi.parsed_stream, st0, b) return nothing
    ca = CallArgs(call, b)

    equals_pos = cursor_equals_position(ca, b)
    should_complete_method_sigs = !ca.has_semicolon && !isnothing(context) &&
        context.triggerCharacter ∈ METHOD_COMPLETION_TRIGGER_CHARACTERS
    should_complete_kwargs = !(equals_pos === true) # is not after `=`

    should_complete_method_sigs || should_complete_kwargs || return nothing

    (; mod, analyzer, postprocessor) = get_context_info(state, uri, pos)
    fntyp = resolve_type(analyzer, mod, call[1])
    fntyp isa Core.Const || return nothing
    candidate_methods = methods(fntyp.val)
    isempty(candidate_methods) && return nothing

    num_existing_args = ca.kw_i - 1
    use_snippet = supports(state, :textDocument, :completion, :completionItem, :snippetSupport)
    modules = should_complete_method_sigs ? Base.loaded_modules_array() : Module[]
    method_sig_sort_idx = 1
    has_equals = equals_pos === false
    kwarg_comp_info = should_complete_kwargs ? (;
        existing_kws = Set{String}(keys(ca.kw_map)),
        seen_kwarg_names = Set{String}(),
        insert_spaces = should_insert_spaces_around_equal(fi, ca),
        local_bindings = has_equals ? nothing : cursor_bindings(st0, b, mod),
        ) : nothing

    for (i, m) in enumerate(candidate_methods)
        startswith(String(m.name), '@') && continue
        compatible_method(m, ca) || continue
        msig = @something get_sig_str(m, ca) continue

        if should_complete_method_sigs
            msig_label = postprocessor(msig)
            base_text = make_insert_text(msig_label, num_existing_args, use_snippet)
            newText = if isnothing(base_text)
                ""
            else
                prefix = (num_existing_args > 0 && context.triggerCharacter == ",") ? " " : ""
                prefix * base_text
            end
            insertTextFormat = use_snippet ? InsertTextFormat.Snippet : InsertTextFormat.PlainText
            label = String(msig_label)
            items[label] = CompletionItem(;
                label,
                labelDetails = CompletionItemLabelDetails(; description = "method"),
                kind = CompletionItemKind.Method,
                textEdit = TextEdit(; range=Range(pos, pos), newText),
                insertTextFormat,
                sortText = get_sort_text(method_sig_sort_idx),
                data = prepare_method_signature_data(m, i, modules),
            )
            method_sig_sort_idx += 1
        else
            @assert should_complete_kwargs && !isnothing(kwarg_comp_info)
            (; existing_kws, seen_kwarg_names, insert_spaces, local_bindings) = kwarg_comp_info
            mnode = JS.parsestmt(JL.SyntaxTree, msig; ignore_errors=true)
            mnode = unwrap_where(mnode)
            JS.kind(mnode) in CALL_KINDS || continue
            params, kwp_i, _ = flatten_args(mnode)
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
                    sortText = max_sort_text1,
                )
            end
        end
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

function lookup_method_from_data(data::MethodSignatureCompletionData)
    modules = Base.loaded_modules_array()
    checkbounds(Bool, modules, data.methodidx) || return nothing
    mod = modules[data.moduleidx]
    for name in data.names
        name = Symbol(name)
        isdefinedglobal(mod, name) || return nothing
        mod = getglobal(mod, name)
    end
    methodname = Symbol(data.methodname)
    isdefinedglobal(mod, methodname) || return nothing
    mfunc = getglobal(mod, methodname)
    ms = methods(mfunc)
    checkbounds(Bool, ms, data.methodidx) || return nothing
    return Pair{Any,Method}(mfunc, ms[data.methodidx])
end

function lookup_method_documentation(@nospecialize(mfunc), m::Method)
    tt = Base.unwrap_unionall(m.sig)
    tt isa DataType || return nothing
    sig = Tuple{tt.parameters[2:end]...}
    return Base.Docs.doc(mfunc, sig)::Markdown.MD
end

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
    elseif data isa MethodSignatureCompletionData
        mfunc, m = @something lookup_method_from_data(data) return item
        doc = @something lookup_method_documentation(mfunc, m) return item
        documentation = string(doc)
        _, result = infer_method!(CC.NativeInterpreter(Base.get_world_counter()), m)
        tt = result.result
        detail = "::" * postprocessor(string(CC.widenconst(tt)))
        return CompletionItem(item;
            labelDetails = CompletionItemLabelDetails(; detail, description = "method"),
            detail,
            documentation = MarkupContent(;
                kind = MarkupKind.Markdown,
                value = documentation))
    else
        return item
    end
end

infer_method!(interp::CC.NativeInterpreter, m::Method) =
    infer_method_signature!(interp, m, m.sig, method_sparams(m))

function method_sparams(m::Method)
    s = TypeVar[]
    sig = m.sig
    while isa(sig, UnionAll)
        push!(s, sig.var)
        sig = sig.body
    end
    return Core.svec(s...)
end

function infer_method_signature!(interp::CC.NativeInterpreter, m::Method, @nospecialize(atype), sparams::Core.SimpleVector)
    mi = CC.specialize_method(m, atype, sparams)::Core.MethodInstance
    return infer_method_instance!(interp, mi)
end

function infer_method_instance!(interp::CC.NativeInterpreter, mi::Core.MethodInstance)
    result = CC.InferenceResult(mi)
    frame = CC.InferenceState(result, #=cache_mode=#:no, interp)
    isnothing(frame) && return interp, result
    return infer_frame!(interp, frame)
end

function infer_frame!(interp::CC.NativeInterpreter, frame::CC.InferenceState)
    Base.invoke_in_world(RT_INF_WORLD[], CC.typeinf, interp, frame)
    return interp, frame.result
end

const RT_INF_WORLD = Ref{UInt}(typemax(UInt))
push_init_hooks!() do
    RT_INF_WORLD[] = Base.get_world_counter()
end

# request handler
# ===============

function get_completion_items(
        state::ServerState, uri::URI, fi::FileInfo,
        pos::Position, context::Union{Nothing,CompletionContext}
    )
    items = Dict{String,CompletionItem}()
    # order matters; see local_completions!
    isIncomplete = @something(
        add_emoji_latex_completions!(items, state, uri, fi, pos),
        call_completions!(items, state, uri, fi, pos, context),
        global_completions!(items, state, uri, fi, pos, context),
        local_completions!(items, state, uri, fi, pos, context),
        keyword_completions!(items, state, context),
        false)
    return collect(values(items)), isIncomplete
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
