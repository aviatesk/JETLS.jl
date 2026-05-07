@interface DocumentLinkClientCapabilities begin
    """
    Whether document link supports dynamic registration.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing

    """
    Whether the client supports the `tooltip` property on `DocumentLink`.

    # Tags
    - since - 3.15.0
    """
    tooltipSupport::Union{Nothing, Bool} = nothing
end

@interface DocumentLinkOptions @extends WorkDoneProgressOptions begin
    """
    Document links have a resolve provider as well.
    """
    resolveProvider::Union{Nothing, Bool} = nothing
end

@interface DocumentLinkRegistrationOptions @extends TextDocumentRegistrationOptions, DocumentLinkOptions begin
end

@interface DocumentLinkParams @extends WorkDoneProgressParams, PartialResultParams begin
    """
    The document to provide document links for.
    """
    textDocument::TextDocumentIdentifier
end

"""
A document link is a range in a text document that links to an internal or
external resource, like another text document or a web site.
"""
@interface DocumentLink begin
    """
    The range this link applies to.
    """
    range::Range

    """
    The uri this link points to. If missing a resolve request is sent later.
    """
    target::Union{Nothing, URI} = nothing

    """
    The tooltip text when you hover over this link.

    If a tooltip is provided, is will be displayed in a string that includes
    instructions on how to trigger the link, such as `{0} (ctrl + click)`.
    The specific instructions vary depending on OS, user settings, and
    localization.

    # Tags
    - since - 3.15.0
    """
    tooltip::Union{Nothing, String} = nothing

    """
    A data entry field that is preserved on a document link between a
    DocumentLinkRequest and a DocumentLinkResolveRequest.
    """
    data::Union{Nothing, LSPAny} = nothing
end

"""
The document links request is sent from the client to the server to request
the location of links in a document.
"""
@interface DocumentLinkRequest @extends RequestMessage begin
    method::String = "textDocument/documentLink"
    params::DocumentLinkParams
end

@interface DocumentLinkResponse @extends ResponseMessage begin
    result::Union{Vector{DocumentLink}, Null, Nothing}
end

"""
The document link resolve request is sent from the client to the server to
resolve the target of a given document link.
"""
@interface DocumentLinkResolveRequest @extends RequestMessage begin
    method::String = "documentLink/resolve"
    params::DocumentLink
end

@interface DocumentLinkResolveResponse @extends ResponseMessage begin
    result::Union{DocumentLink, Nothing}
end
