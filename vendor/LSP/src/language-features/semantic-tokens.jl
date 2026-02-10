"""
A set of predefined token types.

# Tags
- since - 3.16.0
"""
@namespace SemanticTokenTypes::String begin
    namespace = "namespace"
    """
    Represents a generic type. Acts as a fallback for types which
    can't be mapped to a specific type like class or enum.
    """
    type = "type"
    class = "class"
    enum = "enum"
    interface = "interface"
    var"struct" = "struct"
    typeParameter = "typeParameter"
    parameter = "parameter"
    variable = "variable"
    property = "property"
    enumMember = "enumMember"
    event = "event"
    var"function" = "function"
    method = "method"
    var"macro" = "macro"
    keyword = "keyword"
    modifier = "modifier"
    comment = "comment"
    string = "string"
    number = "number"
    regexp = "regexp"
    operator = "operator"
    """
    # Tags
    - since - 3.17.0
    """
    decorator = "decorator"
end

"""
A set of predefined token modifiers.

# Tags
- since - 3.16.0
"""
@namespace SemanticTokenModifiers::String begin
    declaration = "declaration"
    definition = "definition"
    readonly = "readonly"
    static = "static"
    deprecated = "deprecated"
    abstract = "abstract"
    async = "async"
    modification = "modification"
    documentation = "documentation"
    defaultLibrary = "defaultLibrary"
end

"""
The token format.

# Tags
- since - 3.16.0
"""
@namespace TokenFormat::String begin
    Relative = "relative"
end

@interface SemanticTokensLegend begin
    """
    The token types a server uses.
    """
    tokenTypes::Vector{String}

    """
    The token modifiers a server uses.
    """
    tokenModifiers::Vector{String}
end

@interface SemanticTokensClientCapabilities begin
    """
    Whether implementation supports dynamic registration. If this is set to
    `true` the client supports the new `(TextDocumentRegistrationOptions &
    StaticRegistrationOptions)` return value for the corresponding server
    capability as well.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing

    """
    Which requests the client supports and might send to the server
    depending on the server's capability.
    """
    requests::@interface begin
        """
        The client will send the `textDocument/semanticTokens/range` request
        if the server provides a corresponding handler.
        """
        range::Union{Nothing, Bool, @interface begin end} = nothing

        """
        The client will send the `textDocument/semanticTokens/full` request
        if the server provides a corresponding handler.
        """
        full::Union{Nothing, Bool, @interface begin
            """
            The client will send the `textDocument/semanticTokens/full/delta`
            request if the server provides a corresponding handler.
            """
            delta::Union{Nothing, Bool} = nothing
        end} = nothing
    end

    """
    The token types that the client supports.
    """
    tokenTypes::Vector{String}

    """
    The token modifiers that the client supports.
    """
    tokenModifiers::Vector{String}

    """
    The formats the clients supports.
    """
    formats::Vector{TokenFormat.Ty}

    """
    Whether the client supports tokens that can overlap each other.
    """
    overlappingTokenSupport::Union{Nothing, Bool} = nothing

    """
    Whether the client supports tokens that can span multiple lines.
    """
    multilineTokenSupport::Union{Nothing, Bool} = nothing

    """
    Whether the client allows the server to actively cancel a
    semantic token request, e.g. supports returning
    ErrorCodes.ServerCancelled. If a server does the client
    needs to retrigger the request.

    # Tags
    - since - 3.17.0
    """
    serverCancelSupport::Union{Nothing, Bool} = nothing

    """
    Whether the client uses semantic tokens to augment existing
    syntax tokens. If set to `true` client side created syntax
    tokens and semantic tokens are both used for colorization. If
    set to `false` the client only uses the returned semantic tokens
    for colorization.

    If the value is `undefined` then the client behavior is not
    specified.

    # Tags
    - since - 3.17.0
    """
    augmentsSyntaxTokens::Union{Nothing, Bool} = nothing
end

@interface SemanticTokensOptions @extends WorkDoneProgressOptions begin
    """
    The legend used by the server.
    """
    legend::SemanticTokensLegend

    """
    Server supports providing semantic tokens for a specific range
    of a document.
    """
    range::Union{Nothing, Bool, @interface begin end} = nothing

    """
    Server supports providing semantic tokens for a full document.
    """
    full::Union{Nothing, Bool, @interface begin
        """
        The server supports deltas for full documents.
        """
        delta::Union{Nothing, Bool} = nothing
    end} = nothing
end

@interface SemanticTokensRegistrationOptions @extends TextDocumentRegistrationOptions, SemanticTokensOptions, StaticRegistrationOptions begin
end

@interface SemanticTokensParams @extends WorkDoneProgressParams, PartialResultParams begin
    """
    The text document.
    """
    textDocument::TextDocumentIdentifier
end

@interface SemanticTokens begin
    """
    An optional result id. If provided and clients support delta updating
    the client will include the result id in the next semantic token request.
    A server can then instead of computing all semantic tokens again simply
    send a delta.
    """
    resultId::Union{Nothing, String} = nothing

    """
    The actual tokens.
    """
    data::Vector{UInt}
end

@interface SemanticTokensPartialResult begin
    data::Vector{UInt}
end

"""
The request is sent from the client to the server to resolve semantic tokens
for a given file.

# Tags
- since - 3.16.0
"""
@interface SemanticTokensFullRequest @extends RequestMessage begin
    method::String = "textDocument/semanticTokens/full"
    params::SemanticTokensParams
end

@interface SemanticTokensFullResponse @extends ResponseMessage begin
    result::Union{SemanticTokens, Null, Nothing}
end

@interface SemanticTokensDeltaParams @extends WorkDoneProgressParams, PartialResultParams begin
    """
    The text document.
    """
    textDocument::TextDocumentIdentifier

    """
    The result id of a previous response. The result Id can either point to
    a full response or a delta response depending on what was received last.
    """
    previousResultId::String
end

@interface SemanticTokensEdit begin
    """
    The start offset of the edit.
    """
    start::UInt

    """
    The count of elements to remove.
    """
    deleteCount::UInt

    """
    The elements to insert.
    """
    data::Union{Nothing, Vector{UInt}} = nothing
end

@interface SemanticTokensDelta begin
    resultId::Union{Nothing, String} = nothing

    """
    The semantic token edits to transform a previous result into a new
    result.
    """
    edits::Vector{SemanticTokensEdit}
end

@interface SemanticTokensDeltaPartialResult begin
    edits::Vector{SemanticTokensEdit}
end

"""
The request is sent from the client to the server to resolve semantic token
delta for a given file.

# Tags
- since - 3.16.0
"""
@interface SemanticTokensDeltaRequest @extends RequestMessage begin
    method::String = "textDocument/semanticTokens/full/delta"
    params::SemanticTokensDeltaParams
end

@interface SemanticTokensDeltaResponse @extends ResponseMessage begin
    result::Union{SemanticTokens, SemanticTokensDelta, Null, Nothing}
end

@interface SemanticTokensRangeParams @extends WorkDoneProgressParams, PartialResultParams begin
    """
    The text document.
    """
    textDocument::TextDocumentIdentifier

    """
    The range the semantic tokens are requested for.
    """
    range::Range
end

"""
The request is sent from the client to the server to resolve semantic tokens
for a range in a given file.

# Tags
- since - 3.16.0
"""
@interface SemanticTokensRangeRequest @extends RequestMessage begin
    method::String = "textDocument/semanticTokens/range"
    params::SemanticTokensRangeParams
end

@interface SemanticTokensRangeResponse @extends ResponseMessage begin
    result::Union{SemanticTokens, Null, Nothing}
end

"""
Client workspace capabilities specific to semantic tokens.

# Tags
- since - 3.16.0
"""
@interface SemanticTokensWorkspaceClientCapabilities begin
    """
    Whether the client implementation supports a refresh request sent from
    the server to the client.

    Note that this event is global and will force the client to refresh all
    semantic tokens currently shown. It should be used with absolute care
    and is useful for situation where a server for example detect a project
    wide change that requires such a calculation.
    """
    refreshSupport::Union{Nothing, Bool} = nothing
end

"""
The `workspace/semanticTokens/refresh` request is sent from the server to the client.
Servers can use it to ask clients to refresh the editors for which this server provides
semantic tokens.

# Tags
- since - 3.16.0
"""
@interface SemanticTokensRefreshRequest @extends RequestMessage begin
    method::String = "workspace/semanticTokens/refresh"
end

@interface SemanticTokensRefreshResponse @extends ResponseMessage begin
    result::Null
end
