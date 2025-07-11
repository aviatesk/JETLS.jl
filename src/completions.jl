# initialization
# ==============

const NUMERIC_CHARACTERS = tuple(string.('0':'9')...)
const COMPLETION_TRIGGER_CHARACTERS = [
    "@",  # macro completion
    "\\", # LaTeX completion
    ":",  # emoji completion
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
#     id=COMPLETION_REGISTRATION_ID,
#     method=COMPLETION_REGISTRATION_METHOD))
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
function get_sort_text(offset::Int)
    return get(sort_texts, offset, max_sort_text)
end

# local completions
# =================

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
(4) `ci.detail` (possibly at (3))
(5) `ci.documentation`

Sending (4) and (5) to the client can happen eagerly in response to <TAB>
(textDocument/completion), or lazily, on selection in the list
(completionItem/resolve).  The LSP specification notes that more can be deferred
in later versions.
"""
function to_completion(binding::JL.BindingInfo,
                       st::JL.SyntaxTree,
                       sort_offset::Int,
                       uri::URI)
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
    println(io, "```julia")
    JL.showprov(io, st; include_location=false)
    println(io)
    println(io, "```")
    line, character = JS.source_location(st)
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

function local_completions!(items::Dict{String, CompletionItem},
                            s::ServerState, uri::URI, params::CompletionParams)
    let context = params.context
        !isnothing(context) &&
            # Don't trigger completion just by typing a numeric character:
            context.triggerCharacter in NUMERIC_CHARACTERS && return nothing
    end
    fi = get_file_info(s, uri)
    fi === nothing && return nothing
    # NOTE don't bail out even if `length(fi.parsed_stream.diagnostics) ≠ 0`
    # so that we can get some completions even for incomplete code
    st0 = build_tree!(JL.SyntaxTree, fi)
    cbs = cursor_bindings(st0, xy_to_offset(fi, params.position))
    cbs === nothing && return nothing
    for (bi, st, dist) in cbs
        ci = to_completion(bi, st, dist, uri)
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

function global_completions!(items::Dict{String, CompletionItem}, state::ServerState, uri::URI, params::CompletionParams)
    let context = params.context
        !isnothing(context) &&
            # Don't trigger completion just by typing a numeric character:
            context.triggerCharacter in NUMERIC_CHARACTERS && return nothing
    end
    pos = params.position
    fi = get_file_info(state, uri)
    fi === nothing && return nothing
    (; mod, analyzer, postprocessor) = get_context_info(state, uri, pos)
    completion_module = mod

    prev_token_idx = get_prev_token_idx(fi, pos)
    prev_kind = isnothing(prev_token_idx) ? nothing :
        JS.kind(fi.parsed_stream.tokens[prev_token_idx])

    # Case: `@│`
    if prev_kind === JS.K"@"
        edit_start_pos = offset_to_xy(fi, JS.token_first_byte(fi.parsed_stream, prev_token_idx::Int))
        is_macro_invoke = true
    # Case: `@macr│`
    elseif prev_kind === JS.K"MacroName"
        edit_start_pos = offset_to_xy(fi, JS.token_first_byte(fi.parsed_stream, prev_token_idx::Int-1))
        is_macro_invoke = true
    # Case `│` (empty program)
    elseif isnothing(prev_token_idx)
        edit_start_pos = Position(; line=0, character=0)
        is_macro_invoke = false
    elseif JS.is_identifier(prev_kind)
        edit_start_pos = offset_to_xy(fi, JS.token_first_byte(fi.parsed_stream, prev_token_idx::Int))
        is_macro_invoke = false
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

    st = build_tree!(JL.SyntaxTree, fi)
    offset = xy_to_offset(fi, pos)
    dotprefix = select_dotprefix_node(st, offset)
    if !isnothing(dotprefix)
        prefixtyp = resolve_type(analyzer, mod, dotprefix)
        if prefixtyp isa Core.Const
            prefixval = prefixtyp.val
            if prefixval isa Module
                completion_module = prefixval
            end
        end
        # disable local completions for dot-prefixed code for now
        is_completed |= true
    end
    state.completion_resolver_info = (completion_module, postprocessor)

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
        filterText = nothing
        insertTextFormat = InsertTextFormat.PlainText
        if startswith_at
            if endswith(s, "_str")
                description = "string macro"
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
                description = "macro"
            end
        else
            description = "global"
        end
        if name in prioritized_names
            sortText = max_sort_text1
        else
            sortText = max_sort_text2
        end
        textEdit = isnothing(edit_start_pos) ? nothing :
            TextEdit(;
                range = Range(;
                    start = edit_start_pos,
                    var"end" = pos),
                newText)

        items[s] = CompletionItem(;
            label,
            labelDetails = CompletionItemLabelDetails(; description),
            kind = CompletionItemKind.Variable,
            sortText,
            filterText,
            insertTextFormat,
            textEdit,
            data = CompletionData(#=name=#resolveName))
    end

    return is_completed ? items : nothing
end

# LaTeX and emoji completions
# ===========================

"""
    get_backslash_offset(state::ServerState, fi::FileInfo, pos::Position) -> offset::Int, is_emoji::Bool

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
function add_emoji_latex_completions!(items::Dict{String,CompletionItem}, state::ServerState, uri::URI, params::CompletionParams)
    fi = get_file_info(state, uri)
    fi === nothing && return nothing

    pos = params.position
    backslash_offset, emojionly = @something get_backslash_offset(fi, pos) return nothing
    backslash_pos = offset_to_xy(fi, backslash_offset)

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
                range = Range(;
                    start = backslash_pos,
                    var"end" = pos),
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

# completion resolver
# ===================

@define_override_constructor LSP.CompletionItem

function resolve_completion_item(state::ServerState, item::CompletionItem)
    isdefined(state, :completion_resolver_info) || return item
    data = item.data
    data isa CompletionData || return item
    mod, postprocessor = state.completion_resolver_info
    name = Symbol(data.name)
    binding = Base.Docs.Binding(mod, name)
    docs = postprocessor(Base.Docs.doc(binding))
    return CompletionItem(item;
        documentation = MarkupContent(;
            kind = MarkupKind.Markdown,
            value = docs))
end

# request handler
# ===============

function get_completion_items(state::ServerState, uri::URI, params::CompletionParams)
    items = Dict{String, CompletionItem}()
    # order matters; see local_completions!
    return collect(values(@something(
        add_emoji_latex_completions!(items, state, uri, params),
        global_completions!(items, state, uri, params),
        local_completions!(items, state, uri, params),
        items)))
end

function handle_CompletionRequest(server::Server, msg::CompletionRequest)
    uri = msg.params.textDocument.uri
    items = get_completion_items(server.state, uri, msg.params)
    return send(server,
        ResponseMessage(;
            id = msg.id,
            result = CompletionList(;
                isIncomplete = false,
                items)))
end

function handle_CompletionResolveRequest(server::Server, msg::CompletionResolveRequest)
    return send(server,
        ResponseMessage(;
            id = msg.id,
            result = resolve_completion_item(server.state, msg.params)))
end
