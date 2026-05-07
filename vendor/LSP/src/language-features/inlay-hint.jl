"""
Inlay hint client capabilities.

# Tags
- since - 3.17.0
"""
@interface InlayHintClientCapabilities begin
    """
    Whether inlay hints support dynamic registration.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing

    """
    Indicates which properties a client can resolve lazily on an inlay
    hint.
    """
    resolveSupport::Union{Nothing, @interface begin
        """
        The properties that a client can resolve lazily.
        """
        properties::Vector{String}
    end} = nothing
end

"""
Inlay hint options used during static registration.

# Tags
- since - 3.17.0
"""
@interface InlayHintOptions @extends WorkDoneProgressOptions begin
    """
    The server provides support to resolve additional
    information for an inlay hint item.
    """
    resolveProvider::Union{Nothing, Bool} = nothing
end

"""
Inlay hint options used during static or dynamic registration.

# Tags
- since - 3.17.0
"""
@interface InlayHintRegistrationOptions @extends InlayHintOptions, TextDocumentRegistrationOptions, StaticRegistrationOptions begin
end

"""
Inlay hint kinds.

# Tags
- since - 3.17.0
"""
@namespace InlayHintKind::Int begin
    """
    An inlay hint that for a type annotation.
    """
    Type = 1

    """
    An inlay hint that is for a parameter.
    """
    Parameter = 2
end

"""
An inlay hint label part allows for interactive and composite labels
of inlay hints.

# Tags
- since - 3.17.0
"""
@interface InlayHintLabelPart begin
    """
    The value of this label part.
    """
    value::String

    """
    The tooltip text when you hover over this label part. Depending on
    the client capability `inlayHint.resolveSupport` clients might resolve
    this property late using the resolve request.
    """
    tooltip::Union{Nothing, String, MarkupContent} = nothing

    """
    An optional source code location that represents this
    label part.

    The editor will use this location for the hover and for code navigation
    features: This part will become a clickable link that resolves to the
    definition of the symbol at the given location (not necessarily the
    location itself), it shows the hover that shows at the given location,
    and it shows a context menu with further code navigation commands.

    Depending on the client capability `inlayHint.resolveSupport` clients
    might resolve this property late using the resolve request.
    """
    location::Union{Nothing, Location} = nothing

    """
    An optional command for this label part.

    Depending on the client capability `inlayHint.resolveSupport` clients
    might resolve this property late using the resolve request.
    """
    command::Union{Nothing, Command} = nothing
end

"""
Inlay hint information.

# Tags
- since - 3.17.0
"""
@interface InlayHint begin
    """
    The position of this hint.

    If multiple hints have the same position, they will be shown in the order
    they appear in the response.
    """
    position::Position

    """
    The label of this hint. A human readable string or an array of
    InlayHintLabelPart label parts.

    *Note* that neither the string nor the label part can be empty.
    """
    label::Union{String, Vector{InlayHintLabelPart}}

    """
    The kind of this hint. Can be omitted in which case the client
    should fall back to a reasonable default.
    """
    kind::Union{Nothing, InlayHintKind.Ty} = nothing

    """
    Optional text edits that are performed when accepting this inlay hint.

    *Note* that edits are expected to change the document so that the inlay
    hint (or its nearest variant) is now part of the document and the inlay
    hint itself is now obsolete.

    Depending on the client capability `inlayHint.resolveSupport` clients
    might resolve this property late using the resolve request.
    """
    textEdits::Union{Nothing, Vector{TextEdit}} = nothing

    """
    The tooltip text when you hover over this item.

    Depending on the client capability `inlayHint.resolveSupport` clients
    might resolve this property late using the resolve request.
    """
    tooltip::Union{Nothing, String, MarkupContent} = nothing

    """
    Render padding before the hint.

    Note: Padding should use the editor's background color, not the
    background color of the hint itself. That means padding can be used
    to visually align/separate an inlay hint.
    """
    paddingLeft::Union{Nothing, Bool} = nothing

    """
    Render padding after the hint.

    Note: Padding should use the editor's background color, not the
    background color of the hint itself. That means padding can be used
    to visually align/separate an inlay hint.
    """
    paddingRight::Union{Nothing, Bool} = nothing

    """
    A data entry field that is preserved on an inlay hint between
    a `textDocument/inlayHint` and a `inlayHint/resolve` request.
    """
    data::Union{Nothing, LSPAny} = nothing
end

"""
A parameter literal used in inlay hint requests.

# Tags
- since - 3.17.0
"""
@interface InlayHintParams @extends WorkDoneProgressParams begin
    """
    The text document.
    """
    textDocument::TextDocumentIdentifier

    """
    The visible document range for which inlay hints should be computed.
    """
    range::Range
end

"""
The inlay hints request is sent from the client to the server to compute
inlay hints for a given [text document, range] tuple that may be rendered
in the editor in place with other text.

# Tags
- since - 3.17.0
"""
@interface InlayHintRequest @extends RequestMessage begin
    method::String = "textDocument/inlayHint"
    params::InlayHintParams
end

@interface InlayHintResponse @extends ResponseMessage begin
    result::Union{Vector{InlayHint}, Null, Nothing}
end

"""
The request is sent from the client to the server to resolve additional information for a
given inlay hint. This is usually used to compute the `tooltip`, `location` or `command`
properties of an inlay hint's label part to avoid its unnecessary computation during the
`textDocument/inlayHint` request.

Consider the clients announces the `label.location` property as a property that can be
resolved lazy using the client capability

```typescript
textDocument.inlayHint.resolveSupport = { properties: ['label.location'] };
```

then an inlay hint with a label part without a location needs to be resolved using the
`inlayHint/resolve` request before it can be used.

# Tags
- since - 3.17.0
"""
@interface InlayHintResolveRequest @extends RequestMessage begin
    method::String = "inlayHint/resolve"
    params::InlayHint
end

@interface InlayHintResolveResponse @extends ResponseMessage begin
    result::Union{InlayHint, Nothing}
end

"""
Client workspace capabilities specific to inlay hints.

# Tags
- since - 3.17.0
"""
@interface InlayHintWorkspaceClientCapabilities begin
    """
    Whether the client implementation supports a refresh request sent from
    the server to the client.

    Note that this event is global and will force the client to refresh all
    inlay hints currently shown. It should be used with absolute care and
    is useful for situation where a server for example detect a project wide
    change that requires such a calculation.
    """
    refreshSupport::Union{Nothing, Bool} = nothing
end

"""
The `workspace/inlayHint/refresh` request is sent from the server to the client.
Servers can use it to ask clients to refresh the inlay hints currently shown in editors.
As a result the client should ask the server to recompute the inlay hints for these editors.
This is useful if a server detects a configuration change which requires a re-calculation
of all inlay hints. Note that the client still has the freedom to delay the re-calculation
of the inlay hints if for example an editor is currently not visible.

# Tags
- since - 3.17.0
"""
@interface InlayHintRefreshRequest @extends RequestMessage begin
    method::String = "workspace/inlayHint/refresh"
end

@interface InlayHintRefreshResponse @extends ResponseMessage begin
    result::Null
end
