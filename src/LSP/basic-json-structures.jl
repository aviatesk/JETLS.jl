# URI
# ===

const DocumentUri = String
const URI = String

# Position
# ========

"""
Position in a text document expressed as zero-based line and zero-based character offset.
A position is between two characters like an ‘insert’ cursor in an editor.
Special values like for example -1 to denote the end of a line are not supported.
"""
@interface Position begin
    "Line position in a document (zero-based)."
    line::UInt

    """
    Character offset on a line in a document (zero-based). The meaning of this offset is
    determined by the negotiated `PositionEncodingKind`.
    If the character value is greater than the line length it defaults back to the line
    length.
    """
    character::UInt
end

"""
A type indicating how positions are encoded, specifically what column offsets mean.

# Tags
- since – 3.17.0
"""
@namespace PositionEncodingKind::String begin
    """
    Character offsets count UTF-8 code units (e.g bytes).
    """
    UTF8 = "utf-8"

    """
    Character offsets count UTF-16 code units.
    This is the default and must always be supported by servers.
    """
    UTF16 = "utf-16"

    """
    Character offsets count UTF-32 code units.
    Implementation note: these are the same as Unicode code points, so this
    `PositionEncodingKind` may also be used for an encoding-agnostic representation of
    character offsets.
    """
    UTF32 = "utf-32"
end

# Range
# =====

"""
A range in a text document expressed as (zero-based) start and end positions.
A range is comparable to a selection in an editor. Therefore, the end position is exclusive.
If you want to specify a range that contains a line including the line ending character(s)
then use an end position denoting the start of the next line. For example:
```json
{
    start: { line: 5, character: 23 },
    end : { line: 6, character: 0 }
}
```
"""
@interface Range begin
    "The range's start position."
    start::Position

    "The range's end position."
    var"end"::Position
end

# Document, text document
# =======================

"""
An item to transfer a text document from the client to the server.
"""
@interface TextDocumentItem begin
    "The text document's URI."
    uri::DocumentUri

    "The text document's language identifier."
    languageId::String

    """
    The version number of this document (it will increase after each change, including
    undo/redo).
    """
    version::Int

    "The content of the opened text document."
    text::String
end

"""
Text documents are identified using a URI. On the protocol level, URIs are passed as
strings.
The corresponding JSON structure looks like this:
"""
@interface TextDocumentIdentifier begin
    "The text document's URI."
    uri::DocumentUri
end

"""
An identifier to denote a specific version of a text document.
This information usually flows from the client to the server.
"""
@interface VersionedTextDocumentIdentifier @extends TextDocumentIdentifier begin
    """
    The version number of this document.
    The version number of a document will increase after each change, including undo/redo.
    The number doesn't need to be consecutive.
    """
    version::Int
end

"""
An identifier which optionally denotes a specific version of a text document.
This information usually flows from the server to the client.
"""
@interface OptionalVersionedTextDocumentIdentifier @extends TextDocumentIdentifier begin
    """
    The version number of this document. If an optional versioned text document identifier
    is sent from the server to the client and the file is not open in the editor (the server
    has not received an open notification before) the server can send `null` to indicate
    that the version is known and the content on disk is the master (as specified with
    document content ownership).

    The version number of a document will increase after each change, including undo/redo.
    The number doesn't need to be consecutive.
    """
    version::Union{Int, Nothing} = nothing
end

"""
A parameter literal used in requests to pass a text document and a position
inside that document. It is up to the client to decide how a selection is
converted into a position when issuing a request for a text document. The client
can for example honor or ignore the selection direction to make LSP request
    consistent with features implemented internally.
"""
@interface TextDocumentPositionParams begin
    textDocument::TextDocumentIdentifier
    position::Position
end

"""
A document filter denotes a document through properties like language, scheme or pattern.
An example is a filter that applies to TypeScript files on disk. Another example is a filter
that applies to JSON files with name package.json:
```json
{ language: 'typescript', scheme: 'file' }
{ language: 'json', pattern: '**\\/package.json' }
```

Please note that for a document filter to be valid at least one of the properties for
language, scheme, or pattern must be set.
To keep the type definition simple all properties are marked as optional.
"""
@interface DocumentFilter begin
    "A language id, like `typescript`."
    language::Union{String, Nothing} = nothing

    "A Uri scheme, like `file` or `untitled`."
    scheme::Union{String, Nothing} = nothing

    """
    A glob pattern, like `*.{ts,js}`.
    Glob patterns can have the following syntax:
    - `*` to match one or more characters in a path segment
    - `?` to match on one character in a path segment
    - `**` to match any number of path segments, including none
    - `{}` to group sub patterns into an OR expression. (e.g. `**\u200b/*.{ts,js}` matches
      all TypeScript and JavaScript files)
    - `[]` to declare a range of characters to match in a path segment (e.g.,
      `example.[0-9]` to match on `example.0`, `example.1`, …)
    - `[!...]` to negate a range of characters to match in a path segment (e.g.,
      `example.[!0-9]` to match on `example.a`, `example.b`, but not `example.0`)
    """
    pattern::Union{String, Nothing} = nothing
end

"""
A document selector is the combination of one or more document filters.
"""
const DocumentSelector = Vector{DocumentFilter}

# Text Edit
# ==========

@interface TextEdit begin
    "The range of the text document to be manipulated. To insert
    text into a document create a range where start === end."
    range::Range

    "The string to be inserted. For delete operations use an
    empty string."
    newText::String
end

"""
Additional information that describes document changes.

@since 3.16.0
"""
@interface ChangeAnnotation begin
    """
    A human-readable string describing the actual change. The string
    is rendered prominent in the user interface.
     """
    label::String

    """
    A flag which indicates that user confirmation is needed
    before applying the change.
     """
    needsConfirmation::Union{Bool, Nothing} = nothing

    """
    A human-readable string which is rendered less prominent in
    the user interface.
     """
    description::Union{String, Nothing} = nothing
end

"""
An identifier referring to a change annotation managed by a workspace
edit.

# Tags
- since - 3.16.0.
"""
const ChangeAnnotationIdentifier = String

"""
A special text edit with an additional change annotation.

# Tags
- since - 3.16.0.
"""
@interface AnnotatedTextEdit @extends TextEdit begin
    annotationId::ChangeAnnotationIdentifier
end

"""
Represents a location inside a resource, such as a line inside a text file.
"""
@interface Location begin
    uri::DocumentUri
    range::Range
end

# Diagnostic
# ==========

@namespace DiagnosticSeverity::Int begin
    "Reports an error."
    Error = 1

    "Reports a warning."
    Warning = 2

    "Reports an information."
    Information = 3

    "Reports a hint."
    Hint = 4
end

"""
The diagnostic tags.

# Tags
- since – 3.15.0
"""
@namespace DiagnosticTag::Int begin
    """
    Unused or unnecessary code. Clients are allowed to render diagnostics with this tag
    faded out instead of having an error squiggle.
    """
    Unnecessary = 1

    """
    Deprecated or obsolete code. Clients are allowed to rendered diagnostics with this tag
    strike through.
    """
    Deprecated = 2
end

"""
Represents a related message and source code location for a diagnostic.
This should be used to point to code locations that cause or are related to a diagnostics,
e.g when duplicating a symbol in a scope.
"""
@interface DiagnosticRelatedInformation begin
    "The location of this related diagnostic information."
    location::Location

    "The message of this related diagnostic information."
    message::String
end

"""
Structure to capture a description for an error code.

# Tags
- since – 3.16.0
"""
@interface CodeDescription begin
    "An URI to open with more information about the diagnostic error."
    href::URI
end

"""
Represents a diagnostic, such as a compiler error or warning.
Diagnostic objects are only valid in the scope of a resource.
"""
@interface Diagnostic begin
    "The range at which the message applies."
    range::Range

    """
    The diagnostic's severity.
    To avoid interpretation mismatches when a server is used with different clients it is
    highly recommended that servers always provide a severity value.
    If omitted, it’s recommended for the client to interpret it as an Error severity.
    """
    severity::Union{DiagnosticSeverity.Ty, Nothing} = nothing

    "The diagnostic's code, which might appear in the user interface."
    code::Union{Union{Int, String}, Nothing} = nothing

    """
    An optional property to describe the error code.

    # Tags
    - since – 3.16.0
    """
    codeDescription::Union{CodeDescription, Nothing} = nothing

    """
    A human-readable string describing the source of this diagnostic, e.g. 'typescript'
    or 'super lint'.
    """
    source::Union{String, Nothing} = nothing

    "The diagnostic's message."
    message::String

    """
    Additional metadata about the diagnostic.

    # Tags
    - since – 3.15.0
    """
    tags::Union{Vector{DiagnosticTag.Ty}, Nothing} = nothing

    """
    An array of related diagnostic information, e.g. when symbol-names within
    a scope collide all definitions can be marked via this property.
    """
    relatedInformation::Union{Vector{DiagnosticRelatedInformation}, Nothing} = nothing

    """
    A data entry field that is preserved between a `textDocument/publishDiagnostics`
    notification and `textDocument/codeAction` request.

    # Tags
    - since – 3.16.0
    """
    data::Union{Any, Nothing} = nothing
end

"""
Describes the content type that a client supports in various
result literals like `Hover`, `ParameterInfo` or `CompletionItem`.
Please note that `MarkupKinds` must not start with a `\$`. This kinds
are reserved for internal usage.
"""
@namespace MarkupKind::String begin
    "Plain text is supported as a content format"
    PlainText = "plaintext"
    "Markdown is supported as a content format"
    Markdown = "markdown"
end

"""
A `MarkupContent` literal represents a string value which content is
interpreted base on its kind flag. Currently the protocol supports
`plaintext` and `markdown` as markup kinds.

If the kind is `markdown` then the value can contain fenced code blocks like
in GitHub issues.

Here is an example how such a string can be constructed using
JavaScript / TypeScript:
```typescript
let markdown: MarkdownContent = {
    kind: MarkupKind.Markdown,
    value: [
        '# Header',
        'Some text',
        '```typescript',
        'someCode();',
        '```',
    ].join('\n')
};
```

*Please Note* that clients might sanitize the return markdown. A client could
decide to remove HTML from the markdown to avoid script execution.
 */
"""
@interface MarkupContent begin
    "The type of the Markup"
    kind::MarkupKind.Ty

    "The content itself"
    value::String
end

"""
Represents a reference to a command. Provides a title which will be used to
represent a command in the UI. Commands are identified by a string
identifier. The recommended way to handle commands is to implement their
execution on the server side if the client and server provides the corresponding
capabilities. Alternatively the tool extension code could handle the
command. The protocol currently doesn’t specify a set of well-known commands.
"""
@interface Command begin
    "Title of the command, like `save`."
    title::String
    "The identifier of the actual command handler."
    command::String
    "Arguments that the command handler should be invoked with"
    arguments::Union{Vector{Any}, Nothing} = nothing
end

# Work done progress
# ==================

@interface WorkDoneProgressParams begin
    "An optional token that a server can use to report work done progress."
    workDoneToken::Union{ProgressToken, Nothing} = nothing
end

@interface WorkDoneProgressOptions begin
    workDoneProgress::Union{Bool, Nothing} = nothing
end

# Partial results
# ===============

@interface PartialResultParams begin
    """
    An optional token that a server can use to report partial results (e.g. streaming)
    to the client.
    """
    partialResultToken::Union{ProgressToken, Nothing} = nothing
end

# Trace value
# ===========

"""
A TraceValue represents the level of verbosity with which the server systematically reports
its execution trace using \$/logTrace notifications. The initial trace value is set by the
client at initialization and can be modified later using the \$/setTrace notification.
"""
@namespace TraceValue::String begin
    off = "off"
    messages = "messages"
    verbose = "verbose"
end
