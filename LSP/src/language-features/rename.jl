# Rename Request
# ==============

@namespace PrepareSupportDefaultBehavior::Int begin
    """
    The client's default behavior is to select the identifier
    according to the language's syntax rule.
    """
    Identifier = 1
end

@interface RenameClientCapabilities begin
    """
    Whether rename supports dynamic registration.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing

    """
    Client supports testing for validity of rename operations
    before execution.

    # Tags
    - since - version 3.12.0
    """
    prepareSupport::Union{Nothing, Bool} = nothing

    """
    Client supports the default behavior result
    (`{ defaultBehavior: boolean }`).

    The value indicates the default behavior used by the
    client.

    # Tags
    - since - version 3.16.0
    """
    prepareSupportDefaultBehavior::Union{Nothing, PrepareSupportDefaultBehavior.Ty} = nothing

    """
    Whether the client honors the change annotations in
    text edits and resource operations returned via the
    rename request's workspace edit by for example presenting
    the workspace edit in the user interface and asking
    for confirmation.

    # Tags
    - since - 3.16.0
    """
    honorsChangeAnnotations::Union{Nothing, Bool} = nothing
end

@interface RenameOptions @extends WorkDoneProgressOptions begin
    """
    Renames should be checked and tested before being executed.
    """
    prepareProvider::Union{Nothing, Bool} = nothing
end

@interface RenameRegistrationOptions @extends TextDocumentRegistrationOptions, RenameOptions begin
end

@interface RenameParams @extends TextDocumentPositionParams, WorkDoneProgressParams begin
    """
    The new name of the symbol. If the given name is not valid the
    request must return a ResponseError with an
    appropriate message set.
    """
    newName::String
end

"""
The rename request is sent from the client to the server to ask the server to
compute a workspace change so that the client can perform a workspace-wide
rename of a symbol.
"""
@interface RenameRequest @extends RequestMessage begin
    method::String = "textDocument/rename"
    params::RenameParams
end

@interface RenameResponse @extends ResponseMessage begin
    result::Union{WorkspaceEdit, Null, Nothing}
end

# Prepare Rename Request
# ======================

@interface PrepareRenameParams @extends TextDocumentPositionParams begin
end

"""
The prepare rename request is sent from the client to the server to setup and
test the validity of a rename operation at a given location.

# Tags
- since - version 3.12.0
"""
@interface PrepareRenameRequest @extends RequestMessage begin
    method::String = "textDocument/prepareRename"
    params::PrepareRenameParams
end

@interface PrepareRenameResponse @extends ResponseMessage begin
    result::Union{
        Range,
        @interface(begin; range::Range; placeholder::String; end),
        @interface(begin; defaultBehavior::Bool; end),
        Null,
        Nothing
    }
end

# Linked Editing Range
# ====================

@interface LinkedEditingRangeClientCapabilities begin
    """
    Whether the implementation supports dynamic registration.
    If this is set to `true` the client supports the new
    `(TextDocumentRegistrationOptions & StaticRegistrationOptions)`
    return value for the corresponding server capability as well.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing
end

@interface LinkedEditingRangeOptions @extends WorkDoneProgressOptions begin
end

@interface LinkedEditingRangeRegistrationOptions @extends TextDocumentRegistrationOptions, LinkedEditingRangeOptions begin
end

@interface LinkedEditingRangeParams @extends TextDocumentPositionParams begin
end

"""
A list of ranges that can be renamed together. The ranges must have
identical length and contain identical text content. The ranges cannot
overlap.
"""
@interface LinkedEditingRanges begin
    """
    A list of ranges that can be renamed together. The ranges must have
    identical length and contain identical text content. The ranges cannot
    overlap.
    """
    ranges::Vector{Range}

    """
    An optional word pattern (regular expression) that describes valid
    contents for the given ranges. If no pattern is provided, the client
    configuration's word pattern will be used.
    """
    wordPattern::Union{Nothing, String} = nothing
end

"""
The linked editing request is sent from the client to the server to return for
a given position in a document the range of the symbol at the position and all
ranges that have the same content. Optionally a word pattern can be returned to
describe valid contents. A rename to one of the ranges can be applied to all
other ranges if the new content is valid. If no result-specific word pattern is
provided, the word pattern from the client's language configuration is used.

# Tags
- since - version 3.16.0
"""
@interface LinkedEditingRangeRequest @extends RequestMessage begin
    method::String = "textDocument/linkedEditingRange"
    params::LinkedEditingRangeParams
end

@interface LinkedEditingRangeResponse @extends ResponseMessage begin
    result::Union{LinkedEditingRanges, Null, Nothing}
end
