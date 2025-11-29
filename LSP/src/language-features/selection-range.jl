@interface SelectionRangeClientCapabilities begin
    """
    Whether implementation supports dynamic registration for selection range
    providers. If this is set to `true` the client supports the new
    `SelectionRangeRegistrationOptions` return value for the corresponding
    server capability as well.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing
end

@interface SelectionRangeOptions @extends WorkDoneProgressOptions begin
end

@interface SelectionRangeRegistrationOptions @extends TextDocumentRegistrationOptions, SelectionRangeOptions begin
end

@interface SelectionRangeParams @extends WorkDoneProgressParams, PartialResultParams begin
    """
    The text document.
    """
    textDocument::TextDocumentIdentifier

    """
    The positions inside the text document.
    """
    positions::Vector{Position}
end

@interface SelectionRange begin
    """
    The [`Range`](@ref) of this selection range.
    """
    range::Range

    """
    The parent selection range containing this range. Therefore
    `parent.range` must contain `this.range`.
    """
    parent::Union{Nothing, SelectionRange} = nothing
end

"""
The selection range request is sent from the client to the server to return
suggested selection ranges at an array of given positions. A selection range is
a range around the cursor position which the user might be interested in
selecting.

A selection range in the return array is for the position in the provided
parameters at the same index. Therefore `positions[i]` must be contained in
`result[i].range`. To allow for results where some positions have selection
ranges and others do not, `result[i].range` is allowed to be the empty range at
`positions[i]`.

Typically, but not necessary, selection ranges correspond to the nodes of the
syntax tree.

# Tags
- since - 3.15.0
"""
@interface SelectionRangeRequest @extends RequestMessage begin
    method::String = "textDocument/selectionRange"
    params::SelectionRangeParams
end

@interface SelectionRangeResponse @extends ResponseMessage begin
    result::Union{Vector{SelectionRange}, Null, Nothing}
end
