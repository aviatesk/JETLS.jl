struct SetDocumentContentCaller <: RequestCaller end
struct ApplyWorkspaceEditCaller <: RequestCaller end
struct DeleteFileCaller <: RequestCaller end

function set_document_content(server::Server, uri::URI, content::String; context::Union{Nothing,String}=nothing)
    edits = TextEdit[TextEdit(;
        range = Range(;
            start = Position(; line=0, character=0),
            # Use a very large end position to ensure we replace all content
            var"end" = Position(; line=typemax(Int32), character=0)),
        newText = content)]
    changes = Dict{URI,Vector{TextEdit}}(uri => edits)
    edit = WorkspaceEdit(; changes)
    id = unique_id("ApplyWorkspaceEditRequest")
    addrequest!(server, id=>SetDocumentContentCaller())
    label = "Set document content"
    if context !== nothing
        label *= "(for $context)"
    end
    return send(server, ApplyWorkspaceEditRequest(;
        id,
        params = ApplyWorkspaceEditParams(; label, edit)))
end

function handle_apply_workspace_edit_response(
        server::Server, msg::Dict{Symbol,Any},
        ::Union{SetDocumentContentCaller,ApplyWorkspaceEditCaller}
    )
    if handle_response_error(server, msg, "apply workspace edit")
    elseif haskey(msg, :result)
        result = msg[:result] # ::ApplyWorkspaceEditResult
        if haskey(result, "applied") && result["applied"] === true
            # If applied successfully, no action needed
        else
            failure_reason = get(result, "failureReason", "Unknown reason")
            show_error_message(server, "Failed to apply workspace edit: $failure_reason")
        end
    else
        show_error_message(server, "Unexpected response from workspace edit request")
    end
end

function request_delete_file(server::Server, uri::URI)
    delete_op = DeleteFile(;
        kind="delete",
        uri,
        options = DeleteFileOptions(;
            ignoreIfNotExists = true))
    documentChanges = DeleteFile[delete_op]
    edit = WorkspaceEdit(; documentChanges)
    id = unique_id("ApplyWorkspaceEditRequest")
    addrequest!(server, id=>DeleteFileCaller())
    return send(server, ApplyWorkspaceEditRequest(;
        id,
        params = ApplyWorkspaceEditParams(; label="Delete file", edit)))
end

function handle_apply_workspace_edit_response(::Server, ::Dict{Symbol,Any}, ::DeleteFileCaller)
    # Silently ignore errors for file deletion
end

"""
    text_document_workspace_edit(server::Server, uri::URI, version::Union{Int,Null},
                                 text_edit::TextEdit) -> WorkspaceEdit

Return a workspace edit that applies `text_edit` to the document at `uri`, as a document
change for `version` if the client supports `documentChanges`.
"""
function text_document_workspace_edit(
        server::Server, uri::URI, version::Union{Int,Null}, text_edit::TextEdit
    )
    if supports(server, :workspace, :workspaceEdit, :documentChanges)
        document_edit = TextDocumentEdit(;
            textDocument = OptionalVersionedTextDocumentIdentifier(; uri, version),
            edits = TextEdit[text_edit])
        return WorkspaceEdit(;
            documentChanges =
                Union{TextDocumentEdit, CreateFile, RenameFile, DeleteFile}[document_edit])
    end
    return WorkspaceEdit(; changes = Dict{URI,Vector{TextEdit}}(uri => TextEdit[text_edit]))
end
