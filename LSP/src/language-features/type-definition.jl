@interface TypeDefinitionClientCapabilities begin
    """
    Whether type definition supports dynamic registration.
    """
    dynamicRegistration::Union{Bool, Nothing} = nothing

    """
    The client supports additional metadata in the form of definition links.

    # Tags
    - since - 3.14.0
    """
    linkSupport::Union{Bool, Nothing} = nothing
end

@interface TypeDefinitionOptions @extends WorkDoneProgressOptions begin
end

@interface TypeDefinitionRegistrationOptions @extends TextDocumentRegistrationOptions, TypeDefinitionOptions, StaticRegistrationOptions begin
end

@interface TypeDefinitionParams @extends TextDocumentPositionParams, WorkDoneProgressParams, PartialResultParams begin
end

@interface TypeDefinitionRequest @extends RequestMessage begin
    method::String = "textDocument/typeDefinition"
    params::TypeDefinitionParams
end

@interface TypeDefinitionResponse @extends ResponseMessage begin
    result::Union{Location, Vector{Location}, Vector{LocationLink}, Null, Nothing}
end
