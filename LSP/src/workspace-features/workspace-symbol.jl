@interface WorkspaceSymbolClientCapabilities begin
    """
    Symbol request supports dynamic registration.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing

    """
    Specific capabilities for the `SymbolKind` in the `workspace/symbol`
    request.
    """
    symbolKind::Union{Nothing, @interface begin
        """
        The symbol kind values the client supports. When this
        property exists the client also guarantees that it will
        handle values outside its set gracefully and falls back
        to a default value when unknown.

        If this property is not present the client only supports
        the symbol kinds from `File` to `Array` as defined in
        the initial version of the protocol.
        """
        valueSet::Union{Nothing, Vector{SymbolKind.Ty}} = nothing
    end} = nothing

    """
    The client supports tags on `SymbolInformation` and `WorkspaceSymbol`.
    Clients supporting tags have to handle unknown tags gracefully.

    # Tags
    - since - 3.16.0
    """
    tagSupport::Union{Nothing, @interface begin
        """
        The tags supported by the client.
        """
        valueSet::Vector{SymbolTag.Ty}
    end} = nothing

    """
    The client support partial workspace symbols. The client will send the
    request `workspaceSymbol/resolve` to the server to resolve additional
    properties.

    # Tags
    - since - 3.17.0 - proposedState
    """
    resolveSupport::Union{Nothing, @interface begin
        """
        The properties that a client can resolve lazily. Usually
        `location.range`
        """
        properties::Vector{String}
    end} = nothing
end

@interface WorkspaceSymbolOptions @extends WorkDoneProgressOptions begin
    """
    The server provides support to resolve additional
    information for a workspace symbol.

    # Tags
    - since - 3.17.0
    """
    resolveProvider::Union{Nothing, Bool} = nothing
end

@interface WorkspaceSymbolRegistrationOptions @extends WorkspaceSymbolOptions begin
end

"""
The parameters of a Workspace Symbol Request.
"""
@interface WorkspaceSymbolParams @extends WorkDoneProgressParams, PartialResultParams begin
    """
    A query string to filter symbols by. Clients may send an empty
    string here to request all symbols.
    """
    query::String
end

"""
A special workspace symbol that supports locations without a range.

# Tags
- since - 3.17.0
"""
@interface WorkspaceSymbol begin
    """
    The name of this symbol.
    """
    name::String

    """
    The kind of this symbol.
    """
    kind::SymbolKind.Ty

    """
    Tags for this symbol.
    """
    tags::Union{Nothing, Vector{SymbolTag.Ty}} = nothing

    """
    The name of the symbol containing this symbol. This information is for
    user interface purposes (e.g. to render a qualifier in the user interface
    if necessary). It can't be used to re-infer a hierarchy for the document
    symbols.
    """
    containerName::Union{Nothing, String} = nothing

    """
    The location of this symbol. Whether a server is allowed to
    return a location without a range depends on the client
    capability `workspace.symbol.resolveSupport`.

    See also `SymbolInformation.location`.
    """
    location::Union{Location, @interface begin
        uri::DocumentUri
    end}

    """
    A data entry field that is preserved on a workspace symbol between a
    workspace symbol request and a workspace symbol resolve request.
    """
    data::Union{Nothing, LSPAny} = nothing
end

"""
The workspace symbol request is sent from the client to the server to list
project-wide symbols matching the query string. Since 3.17.0 servers can also
provide a handler for `workspaceSymbol/resolve` requests. This allows servers to
return workspace symbols without a range for a `workspace/symbol` request.
Clients then need to resolve the range when necessary using the
`workspaceSymbol/resolve` request. Servers can only use this new model if clients
advertise support for it via the `workspace.symbol.resolveSupport` capability.
"""
@interface WorkspaceSymbolRequest @extends RequestMessage begin
    method::String = "workspace/symbol"
    params::WorkspaceSymbolParams
end

@interface WorkspaceSymbolResponse @extends ResponseMessage begin
    result::Union{Nothing, Vector{SymbolInformation}, Vector{WorkspaceSymbol}}
end

"""
The request is sent from the client to the server to resolve additional
information for a given workspace symbol.
"""
@interface WorkspaceSymbolResolveRequest @extends RequestMessage begin
    method::String = "workspaceSymbol/resolve"
    params::WorkspaceSymbol
end

@interface WorkspaceSymbolResolveResponse @extends ResponseMessage begin
    result::WorkspaceSymbol
end
