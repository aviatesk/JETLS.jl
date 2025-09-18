const RENAME_REGISTRATION_ID = "jetls-rename"
const RENAME_REGISTRATION_METHOD = "textDocument/rename"

function rename_options()
    return RenameOptions(;
        prepareProvider = true
    )
end

function rename_registration()
    return Registration(;
        id = RENAME_REGISTRATION_ID,
        method = RENAME_REGISTRATION_METHOD,
        registerOptions = RenameRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
            prepareProvider = true
        )
    )
end

# # For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id = RENAME_REGISTRATION_ID,
#     method = RENAME_REGISTRATION_METHOD))
# register(currently_running, rename_registration())

function handle_PrepareRenameRequest(server::Server, msg::PrepareRenameRequest)
    uri = msg.params.textDocument.uri
    pos = msg.params.position

    fi = @something get_file_info(server.state, uri) begin
        return send(server,
            PrepareRenameResponse(;
                id = msg.id,
                result = nothing,
                error = file_cache_error(uri)))
    end

    (; mod) = get_context_info(server.state, uri, pos)
    return send(server,
        PrepareRenameResponse(;
            id = msg.id,
            result = @something(
                local_binding_rename_preparation(fi, pos, mod),
                null)))
end

function local_binding_rename_preparation(fi::FileInfo, pos::Position, mod::Module)
    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)

    (; ctx3, binding) = @something begin
        _select_target_binding(st0_top, offset, mod; caller="local_binding_rename_preparation")
    end return nothing

    binfo = JL.lookup_binding(ctx3, binding)
    if is_local_binding(binfo)
        return (; range = jsobj_to_range(binding, fi), placeholder = binfo.name)
    else
        return nothing
    end
end

function handle_RenameRequest(server::Server, msg::RenameRequest)
    uri = msg.params.textDocument.uri
    pos = msg.params.position
    newName = msg.params.newName

    fi = @something get_file_info(server.state, uri) begin
        return send(server,
            RenameResponse(;
                id = msg.id,
                result = nothing,
                error = file_cache_error(uri)))
    end

    (; mod) = get_context_info(server.state, uri, pos)
    (; result, error) = @something(
        local_binding_rename(server, uri, fi, pos, mod, newName),
        (; result = null, error = nothing))
    return send(server, RenameResponse(; id = msg.id, result, error))
end

function local_binding_rename(server::Server, uri::URI, fi::FileInfo, pos::Position, mod::Module, newName::String)
    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)

    (; ctx3, st3, binding) = @something begin
        _select_target_binding(st0_top, offset, mod; caller="local_binding_rename")
    end return nothing

    binfo = JL.lookup_binding(ctx3, binding)
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

    binding_occurrences = compute_binding_occurrences(ctx3, st3)
    haskey(binding_occurrences, binfo) ||
        return (; result = nothing,
            error = ResponseError(;
                code = ErrorCodes.RequestFailed,
                message = "Could not compute information for this local binding."))
    rename_ranges = Set{Range}()
    for occurrence in binding_occurrences[binfo]
        push!(rename_ranges, jsobj_to_range(occurrence.tree, fi))
    end
    edits = TextEdit[TextEdit(; range, newText = newName) for range in rename_ranges]

    if supports(server, :workspace, :workspaceEdit, :documentChanges)
        textDocument = OptionalVersionedTextDocumentIdentifier(; uri, fi.version)
        result = WorkspaceEdit(; documentChanges = TextDocumentEdit[TextDocumentEdit(; textDocument, edits)])
    else
        result = WorkspaceEdit(; changes = Dict(uri => edits))
    end

    return (; result, error = nothing)
end
