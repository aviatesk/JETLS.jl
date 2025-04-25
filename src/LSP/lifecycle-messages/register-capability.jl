"""
Static registration options to be returned in the initialize request.
"""
@interface StaticRegistrationOptions begin
    """
    The id used to register the request. The id can be used to deregister the request again.
    See also Registration#id.
    """
    id::Union{String, Nothing} = nothing
end

"""
General text document registration options.
"""
@interface TextDocumentRegistrationOptions begin
    """
    A document selector to identify the scope of the registration.
    If set to null the document selector provided on the client side will be used.
    """
    documentSelector::Union{DocumentSelector, Nothing}
end
