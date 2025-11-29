"""
A set of predefined range kinds.
"""
@namespace FoldingRangeKind::String begin
    """
    Folding range for a comment
    """
    Comment = "comment"
    """
    Folding range for imports or includes
    """
    Imports = "imports"
    """
    Folding range for a region (e.g. `#region`)
    """
    Region = "region"
end

@interface FoldingRangeClientCapabilities begin
    """
    Whether implementation supports dynamic registration for folding range
    providers. If this is set to `true` the client supports the new
    `FoldingRangeRegistrationOptions` return value for the corresponding
    server capability as well.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing

    """
    The maximum number of folding ranges that the client prefers to receive
    per document. The value serves as a hint, servers are free to follow the
    limit.
    """
    rangeLimit::Union{Nothing, UInt} = nothing

    """
    If set, the client signals that it only supports folding complete lines.
    If set, client will ignore specified `startCharacter` and `endCharacter`
    properties in a FoldingRange.
    """
    lineFoldingOnly::Union{Nothing, Bool} = nothing

    """
    Specific options for the folding range kind.

    # Tags
    - since - 3.17.0
    """
    foldingRangeKind::Union{Nothing, @interface begin
        """
        The folding range kind values the client supports. When this
        property exists the client also guarantees that it will
        handle values outside its set gracefully and falls back
        to a default value when unknown.
        """
        valueSet::Union{Nothing, Vector{FoldingRangeKind.Ty}} = nothing
    end} = nothing

    """
    Specific options for the folding range.

    # Tags
    - since - 3.17.0
    """
    foldingRange::Union{Nothing, @interface begin
        """
        If set, the client signals that it supports setting collapsedText on
        folding ranges to display custom labels instead of the default text.

        # Tags
        - since - 3.17.0
        """
        collapsedText::Union{Nothing, Bool} = nothing
    end} = nothing
end

@interface FoldingRangeOptions @extends WorkDoneProgressOptions begin
end

@interface FoldingRangeRegistrationOptions @extends TextDocumentRegistrationOptions, FoldingRangeOptions begin
end

"""
Represents a folding range. To be valid, start and end line must be bigger
than zero and smaller than the number of lines in the document. Clients
are free to ignore invalid ranges.
"""
@interface FoldingRange begin

    """
    The zero-based start line of the range to fold. The folded area starts
    after the line's last character. To be valid, the end must be zero or
    larger and smaller than the number of lines in the document.
    """
    startLine::UInt

    """
    The zero-based character offset from where the folded range starts. If
    not defined, defaults to the length of the start line.
    """
    startCharacter::Union{Nothing, UInt} = nothing

    """
    The zero-based end line of the range to fold. The folded area ends with
    the line's last character. To be valid, the end must be zero or larger
    and smaller than the number of lines in the document.
    """
    endLine::UInt

    """
    The zero-based character offset before the folded range ends. If not
    defined, defaults to the length of the end line.
    """
    endCharacter::Union{Nothing, UInt} = nothing

    """
    Describes the kind of the folding range such as `comment` or `region`.
    The kind is used to categorize folding ranges and used by commands like
    'Fold all comments'. See [FoldingRangeKind](#FoldingRangeKind) for an
    enumeration of standardized kinds.
    """
    kind::Union{Nothing, FoldingRangeKind.Ty} = nothing

    """
    The text that the client should show when the specified range is
    collapsed. If not defined or not supported by the client, a default
    will be chosen by the client.

    # Tags
    - since - 3.17.0 - proposed
    """
    collapsedText::Union{Nothing, String} = nothing
end

@interface FoldingRangeParams @extends WorkDoneProgressParams, PartialResultParams begin
    """
    The text document.
    """
    textDocument::TextDocumentIdentifier
end

"""
The folding range request is sent from the client to the server to return all
folding ranges found in a given text document.

# Tags
- since - 3.10.0
"""
@interface FoldingRangeRequest @extends RequestMessage begin
    method::String = "textDocument/foldingRange"
    params::FoldingRangeParams
end

@interface FoldingRangeResponse @extends ResponseMessage begin
    result::Union{Vector{FoldingRange}, Null, Nothing}
end
