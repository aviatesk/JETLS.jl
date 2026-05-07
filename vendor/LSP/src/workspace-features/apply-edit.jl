# Apply Workspace Edit
# ====================

"""
The parameters passed via a apply workspace edit request.
"""
@interface ApplyWorkspaceEditParams begin
    """
    An optional label of the workspace edit. This label is
    presented in the user interface for example on an undo
    stack to undo the workspace edit.
    """
    label::Union{Nothing, String} = nothing

    """
    The edits to apply.
    """
    edit::WorkspaceEdit
end

"""
The result returned from the apply workspace edit request.

# Tags
- since - 3.17 renamed from ApplyWorkspaceEditResponse
"""
@interface ApplyWorkspaceEditResult begin
    """
    Indicates whether the edit was applied or not.
    """
    applied::Bool

    """
    An optional textual description for why the edit was not applied.
    This may be used by the server for diagnostic logging or to provide
    a suitable error for a request that triggered the edit.
    """
    failureReason::Union{Nothing, String} = nothing

    """
    Depending on the client's failure handling strategy `failedChange` might
    contain the index of the change that failed. This property is only available
    if the client signals a `failureHandlingStrategy` of `textOnlyTransactional`.
    """
    failedChange::Union{Nothing, UInt} = nothing
end

"""
The `workspace/applyEdit` request is sent from the server to the client to modify
resource on the client side.
"""
@interface ApplyWorkspaceEditRequest @extends RequestMessage begin
    method::String = "workspace/applyEdit"
    params::ApplyWorkspaceEditParams
end

@interface ApplyWorkspaceEditResponse @extends ResponseMessage begin
    result::Union{ApplyWorkspaceEditResult, Nothing}
end
