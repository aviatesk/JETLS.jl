# ------------------------------------------------------------------------------------------
# Position and range.

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

# ------------------------------------------------------------------------------------------
# Folders.

@interface WorkspaceFolder begin
    "The associated URI for this workspace folder."
    uri::URI

    """
    The name of the workspace folder. Used to refer to this workspace folder in the user
    interface.
    """
    name::String
end

# ------------------------------------------------------------------------------------------
# Documents.

const DocumentUri = String

"""
Represents a location inside a resource, such as a line inside a text file.
"""
@interface Location begin
    uri::DocumentUri
    range::Range
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

# -------------------------------------------------------------------
# Text documents.

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
Defines how the host (editor) should sync document changes to the language server.
"""
@namespace TextDocumentSyncKind::Int begin
    "Documents should not be synced at all."
    None = 0

    "Documents are synced by always sending the full content of the document."
    Full = 1

    """
    Documents are synced by sending the full content on open.
    After that only incremental updates to the document are sent.
    """
    Incremental = 2
end

"""
General text document registration options.
"""
@interface TextDocumentRegistrationOptions begin
    """
    A document selector to identify the scope of the registration.
    If set to null the document selector provided on the client side will be used.
    """
    documentSelector::Union{DocumentSelector, Nothing}
end

# --------------------------------------------
# Open.

@interface DidOpenTextDocumentParams begin
    "The document that was opened."
    textDocument::TextDocumentItem
end

"""
The document open notification is sent from the client to the server to signal newly opened
text documents. The document’s content is now managed by the client and the server must not
try to read the document’s content using the document’s Uri. Open in this sense means it is
managed by the client. It doesn’t necessarily mean that its content is presented in an
editor. An open notification must not be sent more than once without a corresponding close
notification send before. This means open and close notification must be balanced and the
max open count for a particular textDocument is one. Note that a server’s ability to
fulfill requests is independent of whether a text document is open or closed.

The `DidOpenTextDocumentParams` contain the language id the document is associated with.
If the language id of a document changes, the client needs to send a `textDocument/didClose`
to the server followed by a `textDocument/didOpen` with the new language id if the server
handles the new language id as well.
"""
@interface DidOpenTextDocumentNotification @extends NotificationMessage begin
    method::String = "textDocument/didOpen"
    params::DidOpenTextDocumentParams
end

# --------------------------------------------
# Close.

@interface DidCloseTextDocumentParams begin
    "The document that was closed."
    textDocument::TextDocumentIdentifier
end

"""
The document close notification is sent from the client to the server when the document got
closed in the client. The document’s master now exists where the document’s Uri points to
(e.g. if the document’s Uri is a file Uri the master now exists on disk). As with the open
notification the close notification is about managing the document’s content.
Receiving a close notification doesn’t mean that the document was open in an editor before.
A close notification requires a previous open notification to be sent. Note that a server’s
ability to fulfill requests is independent of whether a text document is open or closed.
"""
@interface DidCloseTextDocumentNotification @extends NotificationMessage begin
    method::String = "textDocument/didClose"
    params::DidCloseTextDocumentParams
end

# --------------------------------------------
# Change.

"""
Describe options to be used when registering for text document change events.
"""
@interface TextDocumentChangeRegistrationOptions @extends TextDocumentRegistrationOptions begin
    """
    How documents are synced to the server.
    See `TextDocumentSyncKind.Full` and `TextDocumentSyncKind.Incremental`.
    """
    syncKind::TextDocumentSyncKind.Ty
end

"""
An event describing a change to a text document.
If only a text is provided it is considered to be the full content of the document.
"""
@interface TextDocumentContentChangeEvent begin
    "The range of the document that changed."
    range::Union{Range, Nothing} = nothing

    """
    The optional length of the range that got replaced.

    # Tags
    - deprecated – use range instead.
    """
    rangeLength::Union{UInt, Nothing} = nothing

    "The new text for the provided range."
    text::String
end

@interface DidChangeTextDocumentParams begin
    """
    The document that did change. The version number points to the version after all
    provided content changes have been applied.
    """
    textDocument::VersionedTextDocumentIdentifier

    """
    The actual content changes. The content changes describe single state changes to the
    document. So if there are two content changes c1 (at array index 0) and c2 (at array
    index 1) for a document in state S then c1 moves the document from S to S' and c2 from
    S' to S''. So c1 is computed on the state S and c2 is computed on the state S'.

    To mirror the content of a document using change events use the following approach:
    - start with the same initial content
    - apply the 'textDocument/didChange' notifications in the order you receive them.
    - apply the `TextDocumentContentChangeEvent`s in a single notification in the order you
      receive them.
    """
    contentChanges::Vector{TextDocumentContentChangeEvent}
end

"""
The document change notification is sent from the client to the server to signal changes to
a text document. Before a client can change a text document it must claim ownership of its
content using the `textDocument/didOpen` notification.
In 2.0 the shape of the params has changed to include proper version numbers.
"""
@interface DidChangeTextDocumentNotification @extends NotificationMessage begin
    method::String = "textDocument/didChange"
    params::DidChangeTextDocumentParams
end

# --------------------------------------------
# Save.

@interface SaveOptions begin
    "The client is supposed to include the content on save."
    includeText::Union{Bool, Nothing} = nothing
end

@interface DidSaveTextDocumentParams begin
    "The document that was saved."
    textDocument::TextDocumentIdentifier

    """
    Optional the content when saved. Depends on the includeText value when the save
    notification was requested.
    """
    text::Union{String, Nothing} = nothing
end

@interface DidSaveTextDocumentNotification @extends NotificationMessage begin
    method::String = "textDocument/didSave"
    params::DidSaveTextDocumentParams
end

# --------------------------------------------
# Sync.

@interface TextDocumentSyncOptions begin
    """
    Open and close notifications are sent to the server.
    If omitted open close notification should not be sent.
    """
    openClose::Union{Bool, Nothing} = nothing

    """
    Change notifications are sent to the server. See `TextDocumentSyncKind.None`,
    `TextDocumentSyncKind.Full` and `TextDocumentSyncKind.Incremental`.
    If omitted it defaults to `TextDocumentSyncKind.None`.
    """
    change::Union{TextDocumentSyncKind.Ty, Nothing} = nothing

    """
    If present will save notifications are sent to the server.
    If omitted the notification should not be sent.
    """
    willSave::Union{Bool, Nothing} = nothing

    """
    If present will save wait until requests are sent to the server.
    If omitted the request should not be sent.
    """
    willSaveWaitUntil::Union{Bool, Nothing} = nothing

    """
    If present save notifications are sent to the server.
    If omitted the notification should not be sent.
    """
    save::Union{Union{Bool, SaveOptions}, Nothing} = nothing
end

# ------------------------------------------------------------------------------------------
# Files.

"""
A pattern kind describing if a glob pattern matches a file a folder or both.

# Tags
- since – 3.16.0
"""
@namespace FileOperationPatternKind::String begin
    "The pattern matches a file only."
    file = "file"

    "The pattern matches a folder only."
    folder = "folder"
end

"""
Matching options for the file operation pattern.

# Tags
- since – 3.16.0
"""
@interface FileOperationPatternOptions begin
    "The pattern should be matched ignoring casing."
    ignoreCase::Union{Bool, Nothing} = nothing
end

"""
A pattern to describe in which file operation requests or notifications the server is
interested in.

# Tags
- since – 3.16.0
"""
@interface FileOperationPattern begin
    """
    The glob pattern to match. Glob patterns can have the following syntax:
    - `*` to match one or more characters in a path segment
    - `?` to match on one character in a path segment
    - `**` to match any number of path segments, including none
    - `{}` to group sub patterns into an OR expression. (e.g. `**\u200b/*.{ts,js}`
      matches all TypeScript and JavaScript files)
    - `[]` to declare a range of characters to match in a path segment (e.g.,
      `example.[0-9]` to match on `example.0`, `example.1`, …)
    - `[!...]` to negate a range of characters to match in a path segment (e.g.,
      `example.[!0-9]` to match on `example.a`, `example.b`, but not `example.0`)
    """
    glob::String

    "Whether to match files or folders with this pattern. Matches both if undefined."
    matches::Union{FileOperationPatternKind.Ty, Nothing} = nothing

    "Additional options used during matching."
    options::Union{FileOperationPatternOptions, Nothing} = nothing
end

"""
A filter to describe in which file operation requests or notifications the server is
interested in.

# Tags
- since – 3.16.0
"""
@interface FileOperationFilter begin
    "A Uri like `file` or `untitled`."
    scheme::Union{String, Nothing} = nothing

    "The actual file operation pattern."
    pattern::FileOperationPattern
end

"""
The options to register for file operations.

# Tags
- since – 3.16.0
"""
@interface FileOperationRegistrationOptions begin
    "The actual filters."
    filters::Vector{FileOperationFilter}
end
