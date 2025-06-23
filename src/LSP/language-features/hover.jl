@interface HoverClientCapabilities begin
    """
    Whether hover supports dynamic registration.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing

    """
    Client supports the follow content formats if the content
    property refers to a literal of type [`MarkupContent`](@ref).
    The order describes the preferred format of the client.
    """
    contentFormat::Union{Nothing, Vector{MarkupKind.Ty}} = nothing
end

@interface HoverOptions @extends WorkDoneProgressOptions begin
end

@interface HoverRegistrationOptions @extends TextDocumentRegistrationOptions, HoverOptions begin
end

"""
MarkedString can be used to render human readable text. It is either a
markdown string or a code-block that provides a language and a code snippet.
The language identifier is semantically equal to the optional language
identifier in fenced code blocks in GitHub issues.

The pair of a language and a value is an equivalent to markdown:
```\${language}
\${value}
```

Note that markdown strings will be sanitized - that means html will be
escaped.

@deprecated use [`MarkupContent`](@ref) instead.
"""
const MarkedString = Union{String, @NamedTuple begin
    language::String
    value::String
end}

"""
The result of a hover request.
"""
@interface Hover begin
    """
    The hover's content
    """
    contents::Union{MarkedString, Vector{MarkedString}, MarkupContent}

    """
    An optional range is a range inside a text document
    that is used to visualize a hover, e.g. by changing the background color.
    """
    range::Union{Nothing, Range} = nothing
end

@interface HoverParams @extends TextDocumentPositionParams, WorkDoneProgressParams begin
end

"""
The hover request is sent from the client to the server to request hover
information at a given text document position.
"""
@interface HoverRequest @extends RequestMessage begin
    method::String = "textDocument/hover"
    params::HoverParams
end

@interface HoverResponse @extends ResponseMessage begin
    result::Union{Hover, Null}
end
