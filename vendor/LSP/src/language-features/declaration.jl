@interface DeclarationClientCapabilities begin
    """
    Whether declaration supports dynamic registration. If this is set to
    `true` the client supports the new `DeclarationRegistrationOptions`
    return value for the corresponding server capability as well.
    """
    dynamicRegistration::Union{Bool, Nothing} = nothing

    """
    The client supports additional metadata in the form of declaration links.
    """
    linkSupport::Union{Bool, Nothing} = nothing
end

@interface DeclarationOptions @extends WorkDoneProgressOptions begin
end

@interface DeclarationRegistrationOptions @extends DeclarationOptions, TextDocumentRegistrationOptions, StaticRegistrationOptions begin
end

@interface DeclarationParams @extends TextDocumentPositionParams, WorkDoneProgressParams, PartialResultParams begin
end

"""
The go to declaration request is sent from the client to the server to
resolve the declaration location of a symbol at a given text document
position.

The result type `LocationLink[]` got introduced with version 3.14.0 and
depends on the corresponding client capability
`textDocument.declaration.linkSupport`.

# Tags
- since – 3.14.0
"""
@interface DeclarationRequest @extends RequestMessage begin
    method::String = "textDocument/declaration"
    params::DeclarationParams
end

@interface DeclarationResponse @extends ResponseMessage begin
    result::Union{Location, Vector{Location}, Vector{LocationLink}, Null, Nothing}
end
