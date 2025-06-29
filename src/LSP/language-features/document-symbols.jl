# TODO: Remove unnecessary kinds?
"""
A symbol kind.
"""
@namespace SymbolKind::Int begin
    File = 1
    Module = 2
    Namespace = 3
    Package = 4
    Class = 5
    Method = 6
    Property = 7
    Field = 8
    Constructor = 9
    Enum = 10
    Interface = 11
    Function = 12
    Variable = 13
    Constant = 14
    String = 15
    Number = 16
    Boolean = 17
    Array = 18
    Object = 19
    Key = 20
    Null = 21
    EnumMember = 22
    Struct = 23
    Event = 24
    Operator = 25
    TypeParameter = 26
end

"""
Symbol tags are extra annotations that tweak the rendering of a symbol.

# Tags
- since - 3.16
"""
@namespace SymbolTag::Int begin
    "Render a symbol as obsolete, usually using a strike-out."
    Deprecated = 1
end

@interface DocumentSymbolClientCapabilities begin
    """
    Whether document symbol supports dynamic registration.
    """
    dynamicRegistration::Union{boolean, Nothing} = nothing

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
        valueSet::Union{Vector{SymbolKind.Ty}, Nothing} = nothing
    end} = nothing

    """
    The client supports hierarchical document symbols.
    """
    hierarchicalDocumentSymbolSupport::Union{boolean, Nothing} = nothing

    """
    The client supports tags on `SymbolInformation`. Tags are supported on
    `DocumentSymbol` if `hierarchicalDocumentSymbolSupport` is set to true.
    Clients supporting tags have to handle unknown tags gracefully.
    
    # Tags
    - since - 3.16.0
    """
    tagSupport::Union{Nothing, @interface begin
        """
        The tags supported by the client.
        """
        valueSet::Vector{SymbolTag.Ty}
    end} = nothing

    """
    The client supports an additional label presented in the UI when
    registering a document symbol provider.
    
    # Tags
    - since - 3.16.0
    """
    labelSupport::Union{boolean, Nothing} = nothing
end

@interface DocumentSymbolOptions @extends WorkDoneProgressOptions begin
    """
    A human-readable string that is shown when multiple outlines trees
    are shown for the same document.
    
    # Tags
    - since - 3.16.0
    """
    label:: Union{string, Nothing} = nothing
end

@interface DocumentSymbolRegistrationOptions @extends TextDocumentRegistrationOptions, DocumentSymbolOptions begin
end

@interface DocumentSymbolParams @extends WorkDoneProgressParams, PartialResultParams begin
    """
    The text document.
    """
    textDocument::TextDocumentIdentifier
end

"""
Represents programming constructs like variables, classes, interfaces etc.
that appear in a document. Document symbols can be hierarchical and they
have two ranges: one that encloses its definition and one that points to its
most interesting range, e.g. the range of an identifier.
"""
@interface DocumentSymbol begin
    """
    The name of this symbol. Will be displayed in the user interface and
    therefore must not be an empty string or a string only consisting of
    white spaces.
    """
    name::string

    """
    More detail for this symbol, e.g the signature of a function.
    """
    detail::Union{string, Nothing} = nothing

    """
    The kind of this symbol.
    """
    kind::SymbolKind.Ty

    """
    Tags for this document symbol.
    
    # Tags
    - since - 3.16.0
    """
    tags::Union{Vector{SymbolTag.Ty}, Nothing} = nothing

    """
    Indicates if this symbol is deprecated.
    
    # Tags
    - deprecated - Use tags instead
    """
    deprecated::Union{boolean, Nothing} = nothing

    """
    The range enclosing this symbol not including leading/trailing whitespace
    but everything else like comments. This information is typically used to
    determine if the clients cursor is inside the symbol to reveal in the
    symbol in the UI.
    """
    range::Range

    """
    The range that should be selected and revealed when this symbol is being
    picked, e.g. the name of a function. Must be contained by the `range`.
    """
    selectionRange::Range

    """
    Children of this symbol, e.g. properties of a class.
    """
    children::Union{Vector{DocumentSymbol}, Nothing} = nothing
end

# TODO: Remove (deprecated)?
"""
Represents information about programming constructs like variables, classes,
interfaces etc.

# Tags
- deprecated - Use DocumentSymbol or WorkspaceSymbol instead.
"""
@interface SymbolInformation begin
    """
    The name of this symbol.
    """
    name::string

    """
    The kind of this symbol.
    """
    kind::SymbolKind.Ty

    """
    Tags for this symbol.
    
    # Tags
    - since - 3.16.0
    """
    tags::Union{Vector{SymbolTag.Ty}, Nothing} = nothing

    """
    Indicates if this symbol is deprecated.
    
    # Tags
    - deprecated - Use tags instead.
    """
    deprecated::Union{boolean, Nothing} = nothing

    """
    The location of this symbol. The location's range is used by a tool
    to reveal the location in the editor. If the symbol is selected in the
    tool the range's start information is used to position the cursor. So
    the range usually spans more then the actual symbol's name and does
    normally include things like visibility modifiers.
    
    The range doesn't have to denote a node range in the sense of an abstract
    syntax tree. It can therefore not be used to re-construct a hierarchy of
    the symbols.
    """
    location::Location

    """
    The name of the symbol containing this symbol. This information is for
    user interface purposes (e.g. to render a qualifier in the user interface
    if necessary). It can't be used to re-infer a hierarchy for the document
    symbols.
    """
    containerName::Union{string, Nothing} = nothing
end

"""
The document symbol request is sent from the client to the server.
The returned result is either:
    - `SymbolInformation[]` which is a flat list of all symbols found in a given text
      document. Then neither the symbol’s location range nor the symbol’s container name
      should be used to infer a hierarchy.
    - `DocumentSymbol[]` which is a hierarchy of symbols found in a given text document.

Servers should whenever possible return DocumentSymbol since it is the richer
data structure.
"""
@interface DocumentSymbolRequest @extends RequestMessage begin
    method::String = "textDocument/documentSymbol"
    params::DocumentSymbolParams
end

@interface DocumentSymbolResponse @extends ResponseMessage begin
    result::Union{Union{Vector{DocumentSymbol}, Vector{SymbolInformation}}, Nothing} = nothing
end

# TODO: Partial result + error?
