@interface DocumentFormattingClientCapabilities begin
    """
    Whether formatting supports dynamic registration.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing
end

@interface DocumentFormattingOptions @extends WorkDoneProgressOptions begin
end

@interface DocumentFormattingRegistrationOptions @extends TextDocumentRegistrationOptions, DocumentFormattingOptions begin
end

"""
Value-object describing what options formatting should use.
"""
@interface FormattingOptions begin
    """
    Size of a tab in spaces.
    """
    tabSize::UInt

    """
    Prefer spaces over tabs.
    """
    insertSpaces::Bool

    """
    Trim trailing whitespace on a line.

    @since 3.15.0
    """
    trimTrailingWhitespace::Union{Nothing, Bool} = nothing

    """
    Insert a newline character at the end of the file if one does not exist.

    @since 3.15.0
    """
    insertFinalNewline::Union{Nothing, Bool} = nothing

    """
    Trim all newlines after the final newline at the end of the file.

    @since 3.15.0
    """
    trimFinalNewlines::Union{Nothing, Bool} = nothing
end

@interface DocumentFormattingParams @extends WorkDoneProgressParams begin
    """
    The document to format.
    """
    textDocument::TextDocumentIdentifier

    """
    The format options.
    """
    options::FormattingOptions
end

"""
The document formatting request is sent from the client to the server to format
a whole document.
"""
@interface DocumentFormattingRequest @extends RequestMessage begin
    method::String = "textDocument/formatting"
    params::DocumentFormattingParams
end

@interface DocumentFormattingResponse @extends ResponseMessage begin
    result::Union{Vector{TextEdit}, Null, Nothing}
end

@interface DocumentRangeFormattingClientCapabilities begin
    """
    Whether formatting supports dynamic registration.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing
end

@interface DocumentRangeFormattingOptions @extends WorkDoneProgressOptions begin
end

@interface DocumentRangeFormattingRegistrationOptions @extends TextDocumentRegistrationOptions, DocumentRangeFormattingOptions begin
end

@interface DocumentRangeFormattingParams @extends WorkDoneProgressParams begin
    """
    The document to format.
    """
    textDocument::TextDocumentIdentifier

    """
    The range to format
    """
    range::Range

    """
    The format options
    """
    options::FormattingOptions
end

"""
The document range formatting request is sent from the client to the server to
format a given range in a document.
"""
@interface DocumentRangeFormattingRequest @extends RequestMessage begin
    method::String = "textDocument/rangeFormatting"
    params::DocumentRangeFormattingParams
end

@interface DocumentRangeFormattingResponse @extends ResponseMessage begin
    result::Union{Vector{TextEdit}, Null, Nothing}
end

@interface DocumentOnTypeFormattingClientCapabilities begin
    """
    Whether on type formatting supports dynamic registration.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing
end

@interface DocumentOnTypeFormattingOptions begin
    """
    A character on which formatting should be triggered, like `{`.
    """
    firstTriggerCharacter::String

    """
    More trigger characters.
    """
    moreTriggerCharacter::Union{Nothing, Vector{String}} = nothing
end

@interface DocumentOnTypeFormattingRegistrationOptions @extends TextDocumentRegistrationOptions, DocumentOnTypeFormattingOptions begin
end

@interface DocumentOnTypeFormattingParams begin
    """
    The document to format.
    """
    textDocument::TextDocumentIdentifier

    """
    The position around which the on type formatting should happen.
    This is not necessarily the exact position where the character denoted
    by the property `ch` got typed.
    """
    position::Position

    """
    The character that has been typed that triggered the formatting
    on type request. That is not necessarily the last character that
    got inserted into the document since the client could auto insert
    characters as well (e.g. like automatic brace completion).
    """
    ch::String

    """
    The formatting options.
    """
    options::FormattingOptions
end

"""
The document on type formatting request is sent from the client to the server to
format parts of the document during typing.
"""
@interface DocumentOnTypeFormattingRequest @extends RequestMessage begin
    method::String = "textDocument/onTypeFormatting"
    params::DocumentOnTypeFormattingParams
end

@interface DocumentOnTypeFormattingResponse @extends ResponseMessage begin
    result::Union{Vector{TextEdit}, Null, Nothing}
end
