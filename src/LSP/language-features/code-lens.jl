@interface CodeLensClientCapabilities begin
    """
    Whether code lens supports dynamic registration.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing
end

@interface CodeLensOptions @extends WorkDoneProgressOptions begin
    """
    Code lens has a resolve provider as well.
    """
    resolveProvider::Union{Nothing, Bool} = nothing
end

@interface CodeLensRegistrationOptions @extends TextDocumentRegistrationOptions, CodeLensOptions begin
end

@interface CodeLensWorkspaceClientCapabilities begin
    """
    Whether the client implementation supports a refresh request sent from the
    server to the client.

    Note that this event is global and will force the client to refresh all
    code lenses currently shown. It should be used with absolute care and is
    useful for situation where a server for example detect a project wide
    change that requires such a calculation.
    """
    refreshSupport::Union{Nothing, Bool} = nothing
end

"""
A code lens represents a command that should be shown along with
source text, like the number of references, a way to run tests, etc.

A code lens is _unresolved_ when no command is associated to it. For
performance reasons the creation of a code lens and resolving should be done
in two stages.
"""
@interface CodeLens begin
    """
    The range in which this code lens is valid. Should only span a single
    line.
    """
    range::Range

    """
    The command this code lens represents.
    """
    command::Union{Nothing, Command} = nothing

    """
    A data entry field that is preserved on a code lens item between
    a code lens and a code lens resolve request.
    """
    data::Union{Nothing, LSPAny} = nothing
end

@interface CodeLensParams @extends WorkDoneProgressParams, PartialResultParams begin
    """
    The document to request code lens for.
    """
    textDocument::TextDocumentIdentifier
end

"""
The code lens request is sent from the client to the server to compute code lenses
for a given text document.
"""
@interface CodeLensRequest @extends RequestMessage begin
    method::String = "textDocument/codeLens"
    params::CodeLensParams
end

@interface CodeLensResponse @extends ResponseMessage begin
    result::Union{Vector{CodeLens}, Null, Nothing}
end

"""
The code lens resolve request is sent from the client to the server to resolve the
command for a given code lens item.
"""
@interface CodeLensResolveRequest @extends RequestMessage begin
    method::String = "codeLens/resolve"
    params::CodeLens
end

@interface CodeLensResolveResponse @extends ResponseMessage begin
    result::Union{CodeLens, Nothing}
end

"""
The `workspace/codeLens/refresh` request is sent from the server to the client.
Servers can use it to ask clients to refresh the code lenses currently shown in
editors. As a result the client should ask the server to recompute the code lenses
for these editors. This is useful if a server detects a configuration change which
requires a re-calculation of all code lenses. Note that the client still has the
freedom to delay the re-calculation of the code lenses if for example an editor
is currently not visible.

# Tags
- since - 3.16.0
"""
@interface CodeLensRefreshRequest @extends RequestMessage begin
    method::String = "workspace/codeLens/refresh"
    params::Nothing
end

@interface CodeLensRefreshResponse @extends ResponseMessage begin
    result::Union{Null, Nothing}
end
