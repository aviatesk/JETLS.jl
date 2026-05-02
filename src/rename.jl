const RENAME_REGISTRATION_ID = "jetls-rename"
const RENAME_REGISTRATION_METHOD = "textDocument/rename"

function is_macrocall_use_site(fi::FileInfo, tree)
    fb = JS.first_byte(tree)
    return !iszero(fb) && fi.parsed_stream.textbuf[fb] == UInt8('@')
end

struct RenameProgressCaller <: RequestCaller
    uri::URI
    fi::FileInfo
    pos::Position
    newName::String
    msg_id::MessageId
    token::ProgressToken
    cancel_flag::CancelFlag
end
cancellable_token(caller::RenameProgressCaller) = caller.token

function rename_options(server::Server)
    return RenameOptions(;
        prepareProvider = true,
        workDoneProgress = supports(server, :window, :workDoneProgress))
end

function rename_registration(server::Server)
    return Registration(;
        id = RENAME_REGISTRATION_ID,
        method = RENAME_REGISTRATION_METHOD,
        registerOptions = RenameRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
            prepareProvider = true,
            workDoneProgress = supports(server, :window, :workDoneProgress)))
end

# # For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id = RENAME_REGISTRATION_ID,
#     method = RENAME_REGISTRATION_METHOD))
# register(currently_running, rename_registration(currently_running))

function handle_PrepareRenameRequest(
        server::Server, msg::PrepareRenameRequest, cancel_flag::CancelFlag)
    state = server.state
    uri = msg.params.textDocument.uri
    pos = adjust_position(state, uri, msg.params.position)

    result = get_file_info(state, uri, cancel_flag)
    if isnothing(result)
        return send(server, PrepareRenameResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, PrepareRenameResponse(; id = msg.id, result = nothing, error = result))
    end
    fi = result

    (; mod) = get_context_info(state, uri, pos)
    soft_scope = is_notebook_cell_uri(state, uri)
    return send(server,
        PrepareRenameResponse(;
            id = msg.id,
            result = @something(
                local_binding_rename_preparation(state, uri, fi, pos, mod; soft_scope),
                global_binding_rename_preparation(state, uri, fi, pos, mod; soft_scope),
                file_rename_preparation(state, uri, fi, pos),
                null)))
end

function local_binding_rename_preparation(
        state::ServerState, uri::URI, fi::FileInfo, pos::Position, mod::Module;
        soft_scope::Bool = false
    )
    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)

    (; ctx3, binding) = @something begin
        select_target_binding(st0_top, offset, mod; caller="local_binding_rename_preparation", soft_scope)
    end return nothing

    binfo = JL.get_binding(ctx3, binding)
    if is_local_binding(binfo)
        range, _ = unadjust_range(state, uri, jsobj_to_range(binding, fi))
        return (; range, placeholder = binfo.name)
    else
        return nothing
    end
end

function global_binding_rename_preparation(
        state::ServerState, uri::URI, fi::FileInfo, pos::Position, mod::Module;
        soft_scope::Bool = false
    )
    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)

    (; ctx3, binding) = @something begin
        select_target_binding(st0_top, offset, mod; caller="global_binding_rename_preparation", soft_scope)
    end return nothing

    binfo = JL.get_binding(ctx3, binding)
    if binfo.kind === :global
        ismacro = startswith(binfo.name, '@')
        is_macro_use = ismacro && is_macrocall_use_site(fi, binding)
        adjust_first = is_macro_use ? 1 : 0
        range, _ = unadjust_range(state, uri, jsobj_to_range(binding, fi; adjust_first))
        placeholder = ismacro ? String(lstrip(binfo.name, '@')) : binfo.name
        return (; range, placeholder)
    else
        return nothing
    end
end

function file_rename_preparation(
        state::ServerState, uri::URI, fi::FileInfo, pos::Position,
    )
    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)

    string_node = @something begin
        select_target_string(st0_top, offset)
    end return nothing

    resolved = @something(
        resolve_path_string_literal(string_node, dirname(uri2filename(uri))),
        return nothing)
    range, _ = unadjust_range(state, uri, jsobj_to_range(string_node, fi))
    return (; range, placeholder = resolved.value)
end

function handle_RenameRequest(
        server::Server, msg::RenameRequest, cancel_flag::CancelFlag)
    state = server.state
    uri = msg.params.textDocument.uri
    pos = adjust_position(state, uri, msg.params.position)
    newName = msg.params.newName

    result = get_file_info(state, uri, cancel_flag)
    if isnothing(result)
        return send(server, RenameResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, RenameResponse(; id = msg.id, result = nothing, error = result))
    end
    fi = result

    workDoneToken = msg.params.workDoneToken
    if workDoneToken !== nothing
        do_rename(server, uri, fi, pos, newName, msg.id, cancel_flag; token = workDoneToken)
    elseif supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_rename))
        token = String(gensym(:RenameProgress))
        addrequest!(server, id => RenameProgressCaller(uri, fi, pos, newName, msg.id, token, cancel_flag))
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        do_rename(server, uri, fi, pos, newName, msg.id, cancel_flag)
    end

    return nothing
end

function handle_rename_progress_response(
        server::Server, msg::Dict{Symbol,Any}, request_caller::RenameProgressCaller,
        progress_cancel_flag::CancelFlag)
    if handle_response_error(server, msg, "create work done progress")
        return
    end
    (; uri, fi, pos, newName, msg_id, token, cancel_flag) = request_caller
    combined_flag = CombinedCancelFlag(cancel_flag, progress_cancel_flag)
    do_rename(server, uri, fi, pos, newName, msg_id, combined_flag; token)
end

function do_rename(
        server::Server, uri::URI, fi::FileInfo, pos::Position,
        newName::String, msg_id::MessageId, cancel_flag::AbstractCancelFlag;
        token::Union{Nothing,ProgressToken} = nothing)
    (; result, error) = rename(server, uri, fi, pos, newName; token, cancel_flag)
    return send(server, RenameResponse(; id = msg_id, result, error))
end

function rename(
        server::Server, uri::URI, fi::FileInfo, pos::Position, newName::String;
        token::Union{Nothing,ProgressToken} = nothing,
        cancel_flag::AbstractCancelFlag = DUMMY_CANCEL_FLAG)
    (; mod) = get_context_info(server.state, uri, pos)
    soft_scope = is_notebook_cell_uri(server.state, uri)
    return @something(
        local_binding_rename(server, uri, fi, pos, mod, newName; soft_scope),
        global_binding_rename(server, uri, fi, pos, mod, newName; token, cancel_flag, soft_scope),
        file_rename(server, uri, fi, pos, newName),
        (; result = null, error = nothing))
end

function local_binding_rename(
        server::Server, uri::URI, fi::FileInfo, pos::Position, mod::Module, newName::String;
        soft_scope::Bool = false
    )
    state = server.state
    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)

    (; ctx3, st3, st0, binding) = @something begin
        select_target_binding(st0_top, offset, mod; caller="local_binding_rename", soft_scope)
    end return nothing

    binfo = JL.get_binding(ctx3, binding)
    is_local_binding(binfo) || return nothing
    if !Base.isidentifier(newName)
        error = ResponseError(;
            code = ErrorCodes.RequestFailed,
            message = "This variable name cannot be used. Change the name or use var\"...\" syntax.")
        pt = @something(
            prev_nontrivia(fi.parsed_stream, JS.first_byte(binding); strict=true),
            return (; result = nothing, error))
        ppt = @something prev_tok(pt) return (; result = nothing, error)
        if !(JS.kind(pt) === JS.K"\"" && JS.kind(ppt) === JS.K"var")
            return (; result = nothing, error)
        end
    end

    binding_occurrences = compute_binding_occurrences(ctx3, st3, is_generated0(st0))
    haskey(binding_occurrences, binfo) ||
        return (; result = nothing,
            error = ResponseError(;
                code = ErrorCodes.RequestFailed,
                message = "Could not compute information for this local binding."))
    seen_locations = Set{Tuple{URI,Range}}()
    for occurrence in binding_occurrences[binfo]
        range, adjusted_uri = unadjust_range(state, uri, jsobj_to_range(occurrence.tree, fi))
        push!(seen_locations, (adjusted_uri, range))
    end
    edits_by_uri = Dict{URI,Vector{TextEdit}}()
    for (loc_uri, range) in seen_locations
        edit = TextEdit(; range, newText = newName)
        push!(get!(Vector{TextEdit}, edits_by_uri, loc_uri), edit)
    end

    if supports(server, :workspace, :workspaceEdit, :documentChanges)
        documentChanges = TextDocumentEdit[
            TextDocumentEdit(;
                textDocument = OptionalVersionedTextDocumentIdentifier(;
                    uri = edit_uri, version = fi.version),
                edits)
            for (edit_uri, edits) in edits_by_uri]
        result = WorkspaceEdit(; documentChanges)
    else
        result = WorkspaceEdit(; changes = edits_by_uri)
    end

    return (; result, error = nothing)
end

function global_binding_rename(
        server::Server, uri::URI, fi::FileInfo, pos::Position, mod::Module, newName::String;
        token::Union{Nothing,ProgressToken} = nothing,
        cancel_flag::AbstractCancelFlag = DUMMY_CANCEL_FLAG,
        soft_scope::Bool = false
    )
    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)

    (; ctx3, binding) = @something begin
        select_target_binding(st0_top, offset, mod; caller="global_binding_rename", soft_scope)
    end return nothing

    binfo = JL.get_binding(ctx3, binding)
    binfo.kind === :global || return nothing

    if startswith(binfo.name, '@') && startswith(newName, '@')
        newName = String(lstrip(newName, '@'))
    end

    if !Base.isidentifier(newName)
        error = ResponseError(;
            code = ErrorCodes.RequestFailed,
            message = "This variable name cannot be used. Change the name or use var\"...\" syntax.")
        pt = @something(
            prev_nontrivia(fi.parsed_stream, JS.first_byte(binding); strict=true),
            return (; result = nothing, error))
        ppt = @something prev_tok(pt) return (; result = nothing, error)
        if !(JS.kind(pt) === JS.K"\"" && JS.kind(ppt) === JS.K"var")
            return (; result = nothing, error)
        end
    end

    uris_to_search = collect_search_uris(server, uri)
    if token !== nothing
        send_progress(server, token,
            WorkDoneProgressBegin(; title = "Renaming symbol", cancellable = true, percentage = 0))
    end
    if supports(server, :workspace, :workspaceEdit, :documentChanges)
        changes = TextDocumentEdit[]
    else
        changes = Dict{URI,Vector{TextEdit}}()
    end
    local completed = errored = false
    try
        completed = collect_global_rename_edits!(
            changes, server, uris_to_search, binfo, newName, cancel_flag, token)
    catch err
        @error "Error in `global_binding_rename`"
        Base.display_error(stderr, err, catch_backtrace())
        errored = true
    finally
        if token !== nothing
            send_progress(server, token,
                WorkDoneProgressEnd(;
                    message = errored ? "Failed renaming symbol" :
                        !completed ? "Cancelled renaming symbol" :
                        "Completed renaming symbol"))
        end
    end
    if errored
        return (; result = nothing, error = request_failed_error("global_binding_rename failed"))
    elseif !completed
        return (; result = nothing, error = request_cancelled_error("global_binding_rename cancelled"))
    end
    if changes isa Vector{TextDocumentEdit}
        result = WorkspaceEdit(; documentChanges = changes)
    else
        result = WorkspaceEdit(; changes)
    end
    return (; result, error = nothing)
end

function collect_global_rename_edits!(
        changes::Union{Vector{TextDocumentEdit},Dict{URI,Vector{TextEdit}}},
        server::Server, uris_to_search::Set{URI}, binfo::JL.BindingInfo, newName::String,
        cancel_flag::AbstractCancelFlag, token::Union{Nothing,ProgressToken}
    )
    state = server.state
    n_files = length(uris_to_search)
    seen_edits = Set{Tuple{URI,Range,String}}()
    for (i, uri) in enumerate(uris_to_search)
        if is_cancelled(cancel_flag)
            return false
        end

        if token !== nothing
            percentage = round(Int, 100 * (i - 1) / n_files)
            message = "Searching $(basename(uri2filename(uri))) ($i/$n_files)"
            send_progress(server, token,
                WorkDoneProgressReport(; cancellable = true, message, percentage))
        end

        fi = get_file_info(state, uri)
        if fi === nothing
            fi = get_unsynced_file_info!(server.state, uri)
            fi === nothing && continue
            version = null
        else
            version = fi.version
        end
        search_st0_top = build_syntax_tree(fi)
        empty!(seen_edits)
        collect_global_rename_edits_in_file!(
            seen_edits, state, uri, fi, search_st0_top, binfo, newName)
        isempty(seen_edits) && continue

        # Group edits by URI (for notebooks, occurrences may map to different cell URIs)
        edits_by_uri = Dict{URI,Vector{TextEdit}}()
        for (loc_uri, range, newText) in seen_edits
            edit = TextEdit(; range, newText)
            push!(get!(Vector{TextEdit}, edits_by_uri, loc_uri), edit)
        end
        if changes isa Vector{TextDocumentEdit}
            for (edit_uri, edits) in edits_by_uri
                textDocument = OptionalVersionedTextDocumentIdentifier(;
                    uri = edit_uri, version)
                push!(changes, TextDocumentEdit(; textDocument, edits))
            end
        else
            for (edit_uri, edits) in edits_by_uri
                append!(get!(Vector{TextEdit}, changes, edit_uri), edits)
            end
        end
    end
    return true
end

function collect_global_rename_edits_in_file!(
        seen_edits::Set{Tuple{URI,Range,String}}, state::ServerState, uri::URI, fi::FileInfo,
        st0_top::SyntaxTreeC, binfo::JL.BindingInfo, newName::String
    )
    ismacro = startswith(binfo.name, '@')
    for occurrence in find_global_binding_occurrences!(state, uri, fi, st0_top, binfo)
        id_byte_range = JS.byte_range(occurrence.tree)
        classification = classify_import_rename(st0_top, id_byte_range, occurrence.kind)
        if classification === :needs_as
            # Insert ` as <newname>` right after the full identifier (including any
            # leading `@`), keeping the source name intact.
            full_range = jsobj_to_range(occurrence.tree, fi)
            insert_range, adjusted_uri =
                unadjust_range(state, uri, Range(; start=full_range.var"end", var"end"=full_range.var"end"))
            newText = ismacro ? " as @$newName" : " as $newName"
            push!(seen_edits, (adjusted_uri, insert_range, newText))
        elseif classification === :alias && begin
                collapse = collapse_alias_to_source(st0_top, id_byte_range, fi, newName, ismacro)
                collapse !== nothing
            end
            # Renaming an alias back to its source name — drop the ` as <alias>` suffix
            # so the import simplifies to `using M: <source>` instead of `<source> as <source>`.
            collapse_range, adjusted_uri = unadjust_range(state, uri, collapse)
            push!(seen_edits, (adjusted_uri, collapse_range, ""))
        else
            adjust_first = ismacro && is_macrocall_use_site(fi, occurrence.tree) ? 1 : 0
            range, adjusted_uri = unadjust_range(state, uri, jsobj_to_range(occurrence.tree, fi; adjust_first))
            push!(seen_edits, (adjusted_uri, range, newName))
        end
    end
    return seen_edits
end

# Classify a `:decl` occurrence sitting inside an `import`/`using` statement.
# Returns one of:
# - `:regular`        — not in an `import`/`using`; treat as a normal rename.
# - `:alias`          — the identifier is the alias of a `K"as"` node (`using M: foo as bar`);
#                       a standard replace renames only the alias.
# - `:needs_as`       — the identifier is a bare source name in an `import`/`using` form that
#                       accepts `as` (any `import` form, or `using M: name` inside a colon list);
#                       we rewrite `name` → `name as newname` and rename local uses as usual.
# - `:implicit_bare`  — bare source name in `using M`, `using M, N`, or `using M.N` where
#                       `using ... as ...` is not legal syntax; fall back to a standard replace
#                       (breaks code, but matches the rename policy for implicit imports).
function classify_import_rename(st0_top::SyntaxTreeC, id_byte_range::UnitRange{Int}, kind::Symbol)
    kind === :decl || return :regular
    bas = byte_ancestors(st0_top, id_byte_range)
    import_stmt_idx = findfirst(b::SyntaxTreeC -> JS.kind(b) in JS.KSet"import using", bas)
    isnothing(import_stmt_idx) && return :regular
    has_colon = false
    for i = 1:import_stmt_idx-1
        k = JS.kind(bas[i])
        if k === JS.K"as"
            as_node = bas[i]
            if JS.numchildren(as_node) >= 2 && JS.byte_range(as_node[2]) == id_byte_range
                return :alias
            end
            return :regular
        elseif k === JS.K":"
            has_colon = true
        end
    end
    import_kind = JS.kind(bas[import_stmt_idx])
    if import_kind === JS.K"import" || has_colon
        return :needs_as
    end
    return :implicit_bare
end

# If the alias occurrence is being renamed back to the source name of its
# surrounding `K"as"` node, return the LSP range covering ` as <alias>` so a
# single empty-text edit can delete it. Otherwise return `nothing`.
function collapse_alias_to_source(
        st0_top::SyntaxTreeC, id_byte_range::UnitRange{Int}, fi::FileInfo,
        newName::String, ismacro::Bool
    )
    bas = byte_ancestors(st0_top, id_byte_range)
    as_idx = @something findfirst(b::SyntaxTreeC -> JS.kind(b) === JS.K"as", bas) return nothing
    as_node = bas[as_idx]
    JS.numchildren(as_node) >= 2 || return nothing
    source_path = as_node[1]
    source_id = @something get_local_import_identifier(source_path) return nothing
    source_name = get(source_id, :name_val, nothing)
    source_name isa AbstractString || return nothing
    effective_new = ismacro ? "@" * newName : newName
    source_name == effective_new || return nothing
    source_range = jsobj_to_range(source_path, fi)
    alias_range = jsobj_to_range(as_node[2], fi)
    return Range(; start=source_range.var"end", var"end"=alias_range.var"end")
end

function file_rename(
        server::Server, uri::URI, fi::FileInfo, pos::Position, newName::String
    )
    state = server.state
    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)

    string_node = @something begin
        select_target_string(st0_top, offset)
    end return nothing

    basedir = dirname(uri2filename(uri))
    resolved = @something(
        resolve_path_string_literal(string_node, basedir),
        return nothing)
    newPath = joinpath(basedir, newName)

    oldUri = filename2uri(resolved.path)
    newUri = filename2uri(newPath)
    renameFile = RenameFile(; oldUri, newUri)

    range, _ = unadjust_range(state, uri, jsobj_to_range(string_node, fi))
    textEdit = TextEdit(; range, newText = newName)

    if supports(server, :workspace, :workspaceEdit, :documentChanges)
        textDocument = OptionalVersionedTextDocumentIdentifier(; uri, fi.version)
        textDocumentEdit = TextDocumentEdit(; textDocument, edits = [textEdit])
        result = WorkspaceEdit(; documentChanges = [textDocumentEdit, renameFile])
    else
        result = WorkspaceEdit(; changes = Dict(uri => [textEdit]))
    end

    return (; result, error = nothing)
end
