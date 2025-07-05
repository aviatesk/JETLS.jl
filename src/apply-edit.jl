struct SetDocumentContentCaller <: RequestCaller end

function set_document_content(server::Server, uri::URI, content::String; context::Union{Nothing,String}=nothing)
    edits = TextEdit[TextEdit(;
        range = Range(;
            start = Position(; line=0, character=0),
            # Use a very large end position to ensure we replace all content
            var"end" = Position(; line=typemax(Int32), character=0)),
        newText = content)]
    changes = Dict{URI,Vector{TextEdit}}(uri => edits)
    edit = WorkspaceEdit(; changes)
    id = String(gensym(:ApplyWorkspaceEditRequest))
    server.state.currently_requested[id] = SetDocumentContentCaller()
    label = "Set document content"
    if context !== nothing
        label *= "(for $context)"
    end
    return send(server, ApplyWorkspaceEditRequest(;
        id,
        params = ApplyWorkspaceEditParams(; label, edit)))
end
