@interface ExecuteCommandClientCapabilities begin
    """
    Execute command supports dynamic registration.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing
end

@interface ExecuteCommandOptions @extends WorkDoneProgressOptions begin
    """
    The commands to be executed on the server
    """
    commands::Vector{String}
end

"""
Execute command registration options.
"""
@interface ExecuteCommandRegistrationOptions @extends ExecuteCommandOptions begin
end

@interface ExecuteCommandParams @extends WorkDoneProgressParams begin
    """
    The identifier of the actual command handler.
    """
    command::String

    """
    Arguments that the command should be invoked with.
    """
    arguments::Union{Vector{LSPAny}, Nothing} = nothing
end

"""
The workspace/executeCommand request is sent from the client to the server to trigger command
execution on the server. In most cases the server creates a WorkspaceEdit structure and applies
the changes to the workspace using the request workspace/applyEdit which is sent from the server
to the client.
"""
@interface ExecuteCommandRequest @extends RequestMessage begin
    method::String = "workspace/executeCommand"
    params::ExecuteCommandParams
end

@interface ExecuteCommandResponse @extends ResponseMessage begin
    result::LSPAny
end
