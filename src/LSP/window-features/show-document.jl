"""
Client capabilities for the show document request.

# Tags
- since - 3.16.0
"""
@interface ShowDocumentClientCapabilities begin
    """
    The client has support for the show document
    request.
    """
    support::Bool
end

"""
Params to show a resource.

# Tags
- since - 3.16.0
"""
@interface ShowDocumentParams begin
    """
    The uri to show.
    """
    uri::URI

    """
    Indicates to show the resource in an external program.
    To show, for example, `https://code.visualstudio.com/`
    in the default WEB browser set `external` to `true`.
    """
    external::Union{Nothing, Bool} = nothing

    """
    An optional property to indicate whether the editor
    showing the document should take focus or not.
    Clients might ignore this property if an external
    program is started.
    """
    takeFocus::Union{Nothing, Bool} = nothing

    """
    An optional selection range if the document is a text
    document. Clients might ignore the property if an
    external program is started or the file is not a text
    file.
    """
    selection::Union{Nothing, Range} = nothing
end

"""
The result of an show document request.

# Tags
- since - 3.16.0
"""
@interface ShowDocumentResult begin
    """
    A boolean indicating if the show was successful.
    """
    success::Bool
end

"""
The show document request is sent from a server to a client to ask the client to display a
particular resource referenced by a URI in the user interface.

# Tags
- since - 3.16.0
"""
@interface ShowDocumentRequest @extends RequestMessage begin
    method::String = "window/showDocument"
    params::ShowDocumentParams
end

@interface ShowDocumentResponse @extends ResponseMessage begin
    result::ShowDocumentResult
end