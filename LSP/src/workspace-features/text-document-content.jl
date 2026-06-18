"""
Client capabilities for a text document content provider.

- `@since` 3.18.0
"""
@interface TextDocumentContentClientCapabilities begin
    "Text document content provider supports dynamic registration."
    dynamicRegistration::Union{Bool, Nothing} = nothing
end

"""
Text document content provider options.

- `@since` 3.18.0
"""
@interface TextDocumentContentOptions begin
    "The schemes for which the server provides content."
    schemes::Vector{String}
end

"""
Text document content provider registration options.

- `@since` 3.18.0
"""
@interface TextDocumentContentRegistrationOptions @extends TextDocumentContentOptions, StaticRegistrationOptions begin
end

"""
Parameters for the `workspace/textDocumentContent` request.

- `@since` 3.18.0
"""
@interface TextDocumentContentParams begin
    "The uri of the text document."
    uri::DocumentUri
end

"""
Result of the `workspace/textDocumentContent` request.

- `@since` 3.18.0
"""
@interface TextDocumentContentResult begin
    """
    The text content of the text document. Please note, that the content of any
    subsequent open notifications for the text document might differ from the
    returned content due to whitespace and line ending normalizations done on
    the client.
    """
    text::String
end

"""
The `workspace/textDocumentContent` request is sent from the client to the
server to dynamically fetch the content of a text document. Clients should treat
the returned content as readonly.

- `@since` 3.18.0
"""
@interface TextDocumentContentRequest @extends RequestMessage begin
    method::String = "workspace/textDocumentContent"
    params::TextDocumentContentParams
end

@interface TextDocumentContentResponse @extends ResponseMessage begin
    result::Union{TextDocumentContentResult, Nothing}
end

"""
Parameters for the `workspace/textDocumentContent/refresh` request.

- `@since` 3.18.0
"""
@interface TextDocumentContentRefreshParams begin
    "The uri of the text document to refresh."
    uri::DocumentUri
end

"""
The `workspace/textDocumentContent/refresh` request is sent from the server to
the client to refresh the content of a specific text document.

- `@since` 3.18.0
"""
@interface TextDocumentContentRefreshRequest @extends RequestMessage begin
    method::String = "workspace/textDocumentContent/refresh"
    params::TextDocumentContentRefreshParams
end

@interface TextDocumentContentRefreshResponse @extends ResponseMessage begin
    result::Union{Null, Nothing}
end
