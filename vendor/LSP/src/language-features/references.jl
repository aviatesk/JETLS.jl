@interface ReferenceClientCapabilities begin
    """
    Whether references supports dynamic registration.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing
end

@interface ReferenceOptions @extends WorkDoneProgressOptions begin
end

@interface ReferenceRegistrationOptions @extends TextDocumentRegistrationOptions, ReferenceOptions begin
end

@interface ReferenceContext begin
    """
    Include the declaration of the current symbol.
    """
    includeDeclaration::Bool
end

@interface ReferenceParams @extends TextDocumentPositionParams, WorkDoneProgressParams, PartialResultParams begin
    context::ReferenceContext
end

"""
The references request is sent from the client to the server to resolve project-wide
references for the symbol denoted by the given text document position.
"""
@interface ReferencesRequest @extends RequestMessage begin
    method::String = "textDocument/references"
    params::ReferenceParams
end

@interface ReferencesResponse @extends ResponseMessage begin
    result::Union{Vector{Location}, Null, Nothing}
end
