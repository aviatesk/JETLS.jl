@interface DocumentSymbolClientCapabilities begin
    """
    Whether document symbol supports dynamic registration.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing

    """
    Specific capabilities for the `SymbolKind` in the
    `textDocument/documentSymbol` request.
    """
    symbolKind::Union{Nothing, @interface begin
        """
        The symbol kind values the client supports. When this
        property exists the client also guarantees that it will
        handle values outside its set gracefully and falls back
        to a default value when unknown.

        If this property is not present the client only supports
        the symbol kinds from `File` to `Array` as defined in
        the initial version of the protocol.
        """
        valueSet::Union{Nothing, Vector{SymbolKind.Ty}} = nothing
    end} = nothing

    """
    The client supports hierarchical document symbols.
    """
    hierarchicalDocumentSymbolSupport::Union{Nothing, Bool} = nothing

    """
    The client supports tags on `SymbolInformation`. Tags are supported on
    `DocumentSymbol` if `hierarchicalDocumentSymbolSupport` is set to true.
    Clients supporting tags have to handle unknown tags gracefully.

    # Tags
    - since - 3.16.0
    """
    tagSupport::Union{Nothing, @interface begin
        "The tags supported by the client."
        valueSet::Vector{SymbolTag.Ty}
    end} = nothing

    """
    The client supports an additional label presented in the UI when
    registering a document symbol provider.

    # Tags
    - since - 3.16.0
    """
    labelSupport::Union{Nothing, Bool} = nothing
end

@interface DocumentSymbolOptions @extends WorkDoneProgressOptions begin
    """
    A human-readable string that is shown when multiple outlines trees
    are shown for the same document.

    # Tags
    - since - 3.16.0
    """
    label::Union{Nothing, String} = nothing
end

@interface DocumentSymbolRegistrationOptions @extends TextDocumentRegistrationOptions, DocumentSymbolOptions begin
end

@interface DocumentSymbolParams @extends WorkDoneProgressParams, PartialResultParams begin
    "The text document."
    textDocument::TextDocumentIdentifier
end

"""
Represents programming constructs like variables, classes, interfaces etc.
that appear in a document. Document symbols can be hierarchical and they
have two ranges: one that encloses its definition and one that points to
its most interesting range, e.g. the range of an identifier.
"""
@interface DocumentSymbol begin
    "The name of this symbol. Will be displayed in the user interface and therefore must not be an empty string or a string only consisting of white spaces."
    name::String

    "More detail for this symbol, e.g the signature of a function."
    detail::Union{Nothing, String} = nothing

    "The kind of this symbol."
    kind::SymbolKind.Ty

    """
    Tags for this document symbol.

    # Tags
    - since - 3.16.0
    """
    tags::Union{Nothing, Vector{SymbolTag.Ty}} = nothing

    """
    Indicates if this symbol is deprecated.

    @deprecated Use tags instead
    """
    deprecated::Union{Nothing, Bool} = nothing

    """
    The range enclosing this symbol not including leading/trailing whitespace but everything else
    like comments. This information is typically used to determine if the clients cursor is
    inside the symbol to reveal in the symbol in the UI.
    """
    range::Range

    """
    The range that should be selected and revealed when this symbol is being picked,
    e.g. the name of a function.
    Must be contained by the `range`.
    """
    selectionRange::Range

    "Children of this symbol, e.g. properties of a class."
    children::Union{Nothing, Vector{DocumentSymbol}} = nothing
end

"""
The document symbol request is sent from the client to the server.
The returned result is either:
- `SymbolInformation[]` which is a flat list of all symbols found in a given text document.
  Then neither the symbol's location range nor the symbol's container name should be used to
  infer a hierarchy.
- `DocumentSymbol[]` which is a hierarchy of symbols found in a given text document.

Servers should whenever possible return [`DocumentSymbol`](@ref) since it is the richer data structure.
"""
@interface DocumentSymbolRequest @extends RequestMessage begin
    method::String = "textDocument/documentSymbol"
    params::DocumentSymbolParams
end

@interface DocumentSymbolResponse @extends ResponseMessage begin
    result::Union{Vector{DocumentSymbol}, Vector{SymbolInformation}, Null, Nothing}
end
