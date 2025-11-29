@interface DocumentHighlightClientCapabilities begin
    """
    Whether document highlight supports dynamic registration.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing
end

@interface DocumentHighlightOptions @extends WorkDoneProgressOptions begin
end

@interface DocumentHighlightRegistrationOptions @extends TextDocumentRegistrationOptions, DocumentHighlightOptions begin
end

"""
A document highlight kind.
"""
@namespace DocumentHighlightKind::Int begin
    """
    A textual occurrence.
    """
    Text = 1
    """
    Read-access of a symbol, like reading a variable.
    """
    Read = 2
    """
    Write-access of a symbol, like writing to a variable.
    """
    Write = 3
end

"""
A document highlight is a range inside a text document which deserves
special attention. Usually a document highlight is visualized by changing
the background color of its range.
"""
@interface DocumentHighlight begin
    """
    The range this highlight applies to.
    """
    range::Range

    """
    The highlight kind, default is DocumentHighlightKind.Text.
    """
    kind::Union{Nothing, DocumentHighlightKind.Ty} = nothing
end

@interface DocumentHighlightParams @extends TextDocumentPositionParams, WorkDoneProgressParams, PartialResultParams begin
end

"""
The document highlight request is sent from the client to the server to resolve
document highlights for a given text document position. For programming languages
this usually highlights all references to the symbol scoped to this file. However,
we kept 'textDocument/documentHighlight' and 'textDocument/references' separate
requests since the first one is allowed to be more fuzzy. Symbol matches usually
have a DocumentHighlightKind of Read or Write whereas fuzzy or textual matches use
Text as the kind.
"""
@interface DocumentHighlightRequest @extends RequestMessage begin
    method::String = "textDocument/documentHighlight"
    params::DocumentHighlightParams
end

@interface DocumentHighlightResponse @extends ResponseMessage begin
    result::Union{Vector{DocumentHighlight}, Null, Nothing}
end