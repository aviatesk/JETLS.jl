@interface DefinitionClientCapabilities begin
    """
    Whether definition supports dynamic registration.
    """
    dynamicRegistration::Union{Bool, Nothing} = nothing

    """
    The client supports additional metadata in the form of definition links.
    
    - since 3.14.0
    """
    linkSupport::Union{Bool, Nothing} = nothing
end

@interface DefinitionOptions @extends WorkDoneProgressOptions begin
end

@interface DefinitionRegistrationOptions @extends TextDocumentRegistrationOptions, DefinitionOptions begin
end

@interface DefinitionParams @extends TextDocumentPositionParams, WorkDoneProgressParams, PartialResultParams begin
end

@interface DefinitionRequest @extends RequestMessage begin
    method::String = "textDocument/definition"
    params::DefinitionParams
end

@interface DefinitionResponse @extends ResponseMessage begin
    result::Union{Location, Vector{Location}, Vector{LocationLink}, Nothing}
end