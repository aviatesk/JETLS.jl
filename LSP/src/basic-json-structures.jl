# URI
# ===

const __URI_DOC__ = """
According to the LSP, any fields declared as `DocumentUri` and `URI` types
(in the TypeScript definition) are:
> Over the wire, it will still be transferred as a string, but this guarantees that
> the contents of that string can be parsed as a valid URI.

In actual language server implementations, the values of such `DocumentUri` and `URI` type
fields are parsed and used as data structures representing URIs that comply with
https://datatracker.ietf.org/doc/html/rfc3986,
having `scheme`, `authority`, `path`, `query`, and `fragment` components.

In JETLS, `URIs2.URI` corresponds to such a data structure.

If we were to strictly adhere to the LSP definition, these fields should be defined as
`String` type, and `DocumentUri` and `URI` should be aliases to `String`.
However, in our Julia version of the LSP definition, for implementation simplicity, we
automatically `convert` URI-representing fields to `URIs2.URI` during JSON3 parsing,
allowing the language server to directly handle `URIs2.URI`.
"""
# const DocumentUri = String
# const URI = String
const DocumentUri = URI

@doc __URI_DOC__ DocumentUri
@doc __URI_DOC__ URI

# Regular Expressions
# ===================

"""
Client capabilities specific to regular expressions.
"""
@interface RegularExpressionsClientCapabilities begin
    """
    The engine's name.
    """
    engine::String

    """
    The engine's version.
    """
    version::Union{String, Nothing} = nothing
end

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

# TextEdit & AnnotatedTextEdit
# ============================

"""
A textual edit applicable to a text document.
"""
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

Since 3.16.0 there is also the concept of an annotated text edit which supports to add
an annotation to a text edit.
The annotation can add information describing the change to the text edit.

Usually clients provide options to group the changes along the annotations they are
associated with. To support this in the protocol an edit or resource operation refers
to a change annotation using an identifier and not the change annotation literal
directly. This allows servers to use the identical annotation across multiple edits or
resource operations which then allows clients to group the operations under that change
annotation. The actual change annotations together with their identifiers are managed
by the workspace edit via the new property `changeAnnotations`.

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
Complex text manipulations are described with an array of [`TextEdit`](#textedit[])'s or
[`AnnotatedTextEdit`](#annotatedTextEdit)'s, representing a single change to the
document.

All text edits ranges refer to positions in the document they are computed on. They
therefore move a document from state S1 to S2 without describing any intermediate
state. Text edits ranges must never overlap, that means no part of the original
document must be manipulated by more than one edit. However, it is possible that
multiple edits have the same start position: multiple inserts, or any number of
inserts followed by a single remove or replace edit. If multiple inserts have the same
position, the order in the array defines the order in which the inserted strings
appear in the resulting text.
"""
var"TextEdit[]"

"""
New in version 3.16: support for [`AnnotatedTextEdit`](@ref). The support
is guarded by the client capability `workspace.workspaceEdit.changeAnnotationSupport`.
If a client doesn't signal the capability, servers shouldn't send
[`AnnotatedTextEdit`](@ref) literals back to the client.

Describes textual changes on a single text document. The text document is referred to as
a [`OptionalVersionedTextDocumentIdentifier`](@ref) to allow clients to check the text
document version before an edit is applied. A [`TextDocumentEdit`](@ref) describes all
changes on a version Si and after they are applied move the document to version Si+1.
So the creator of a [`TextDocumentEdit`](@ref) doesn't need to sort the array of edits
or do any kind of ordering. However the edits must be non overlapping.
"""
@interface TextDocumentEdit begin
    """
    The text document to change.
    """
    textDocument::OptionalVersionedTextDocumentIdentifier

    """
    The edits to be applied.

    # Tags
    - since - 3.16.0 - support for AnnotatedTextEdit. This is guarded by the
      client capability `workspace.workspaceEdit.changeAnnotationSupport`
    """
    edits::Vector{Union{TextEdit, AnnotatedTextEdit}}
end

"""
Represents a location inside a resource, such as a line inside a text file.
"""
@interface Location begin
    uri::DocumentUri
    range::Range
end

"""
Represents a link between a source and a target location.

# Tags
- since 3.14.0
"""
@interface LocationLink begin
    """
    Span of the origin of this link.

    Used as the underlined span for mouse interaction. Defaults to the word
    range at the mouse position.
    """
    originSelectionRange::Union{Range, Nothing} = nothing

    """
    The target resource identifier of this link.
    """
    targetUri::DocumentUri

    """
    The full target range of this link. If the target for example is a symbol
    then target range is the range enclosing this symbol not including
    leading/trailing whitespace but everything else like comments. This
    information is typically used to highlight the range in the editor.
    """
    targetRange::Range

    """
    The range that should be selected and revealed when this link is being
    followed, e.g the name of a function. Must be contained by the
    `targetRange`. See also [`Range`](@ref).
    """
    targetSelectionRange::Range
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
    code::Union{Int, String, Nothing} = nothing

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

# Command
# =======

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

# MarkupContent
# =============

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
"""
@interface MarkupContent begin
    "The type of the Markup"
    kind::MarkupKind.Ty

    "The content itself"
    value::String
end

"""
Client capabilities specific to the used markdown parser.

In addition clients should signal the markdown parser they are using via the client
capability general.markdown introduced in version 3.16.0 defined as follows.

Known markdown parsers used by clients right now are:

| Parser | Version | Documentation |
| --- | --- | --- |
| marked | 1.1.0 | [Marked Documentation](https://marked.js.org/) |
| Python-Markdown | 3.2.2 | [Python-Markdown Documentation](https://python-markdown.github.io/) |

# Tags
- since – 3.16.0
"""
@interface MarkdownClientCapabilities begin
    """
    The name of the parser.
    """
    parser::String

    """
    The version of the parser.
    """
    version::Union{String, Nothing} = nothing

    """
    A list of HTML tags that the client allows / supports in
    Markdown.

    # Tags
    - since – 3.17.0
    """
    allowedTags::Union{Vector{String}, Nothing} = nothing
end

# File Resource changes
# =====================

"""
New in version 3.13. Since version 3.16 file resource changes can carry an additional
property `changeAnnotation` to describe the actual change in more detail. Whether a
client has support for change annotations is guarded by the client capability
`workspace.workspaceEdit.changeAnnotationSupport`.

File resource changes allow servers to create, rename and delete files and folders via
the client. Note that the names talk about files but the operations are supposed to
work on files and folders. This is in line with other naming in the Language Server
Protocol (see file watchers which can watch files and folders). The corresponding
change literals look as follows:
"""

@interface CreateFileOptions begin
    """
    Overwrite existing file. Overwrite wins over `ignoreIfExists`
    """
    overwrite::Union{Nothing, Bool} = nothing

    """
    Ignore if exists.
    """
    ignoreIfExists::Union{Nothing, Bool} = nothing
end

"""
Create file operation
"""
@interface CreateFile begin
    """
    A create
    """
    kind::String = "create"

    """
    The resource to create.
    """
    uri::DocumentUri

    """
    Additional options
    """
    options::Union{Nothing, CreateFileOptions} = nothing

    """
    An optional annotation identifier describing the operation.

    # Tags
    - since - 3.16.0
    """
    annotationId::Union{Nothing, ChangeAnnotationIdentifier} = nothing
end

@interface RenameFileOptions begin
    """
    Overwrite target if existing. Overwrite wins over `ignoreIfExists`
    """
    overwrite::Union{Nothing, Bool} = nothing

    """
    Ignores if target exists.
    """
    ignoreIfExists::Union{Nothing, Bool} = nothing
end

"""
Rename file operation
"""
@interface RenameFile begin
    """
    A rename
    """
    kind::String = "rename"

    """
    The old (existing) location.
    """
    oldUri::DocumentUri

    """
    The new location.
    """
    newUri::DocumentUri

    """
    Rename options.
    """
    options::Union{Nothing, RenameFileOptions} = nothing

    """
    An optional annotation identifier describing the operation.

    # Tags
    - since - 3.16.0
    """
    annotationId::Union{Nothing, ChangeAnnotationIdentifier} = nothing
end

@interface DeleteFileOptions begin
    """
    Delete the content recursively if a folder is denoted.
    """
    recursive::Union{Nothing, Bool} = nothing

    """
    Ignore the operation if the file doesn't exist.
    """
    ignoreIfNotExists::Union{Nothing, Bool} = nothing
end

"""
Delete file operation
"""
@interface DeleteFile begin
    """
    A delete
    """
    kind::String = "delete"

    """
    The resource to delete.
    """
    uri::DocumentUri

    """
    Delete options.
    """
    options::Union{Nothing, DeleteFileOptions} = nothing

    """
    An optional annotation identifier describing the operation.

    # Tags
    - since - 3.16.0
    """
    annotationId::Union{Nothing, ChangeAnnotationIdentifier} = nothing
end

@namespace ResourceOperationKind::String begin
    """
    Supports creating new files and folders.
    """
    Create = "create"

    """
    Supports renaming existing files and folders.
    """
    Rename = "rename"

    """
    Supports deleting existing files and folders.
    """
    Delete = "delete"
end

@namespace FailureHandlingKind::String begin
    """
    Applying the workspace change is simply aborted if one of the changes
    provided fails. All operations executed before the failing operation
    stay executed.
    """
    Abort = "abort"

    """
    All operations are executed transactional. That means they either all
    succeed or no changes at all are applied to the workspace.
    """
    Transactional = "transactional"

    """
    If the workspace edit contains only textual file changes they are
    executed transactional. If resource changes (create, rename or delete
    file) are part of the change the failure handling strategy is abort.
    """
    TextOnlyTransactional = "textOnlyTransactional"

    """
    The client tries to undo the operations already executed. But there is no
    guarantee that this is succeeding.
    """
    Undo = "undo"
end

# Workspace Edit
# ==============

"""
A workspace edit represents changes to many resources managed in the workspace.
The edit should either provide `changes` or `documentChanges`.
If the client can handle versioned document edits and if `documentChanges` are present,
the latter are preferred over `changes`.

Since version 3.13.0 a workspace edit can contain resource operations
(create, delete or rename files and folders) as well.
If resource operations are present clients need to execute the operations in the order
in which they are provided. So a workspace edit for example can consist of the
following two changes: (1) create file a.txt and (2) a text document edit which insert
text into file a.txt. An invalid sequence (e.g. (1) delete file a.txt and (2) insert
text into file a.txt) will cause failure of the operation. How the client recovers from
the failure is described by the client capability:
`workspace.workspaceEdit.failureHandling`
"""
@interface WorkspaceEdit begin
    """
    Holds changes to existing resources.
    """
    changes::Union{Nothing, Dict{DocumentUri, Vector{TextEdit}}} = nothing

    """
    Depending on the client capability
    `workspace.workspaceEdit.resourceOperations` document changes are either
    an array of `TextDocumentEdit`s to express changes to n different text
    documents where each text document edit addresses a specific version of
    a text document. Or it can contain above `TextDocumentEdit`s mixed with
    create, rename and delete file / folder operations.

    Whether a client supports versioned document edits is expressed via
    `workspace.workspaceEdit.documentChanges` client capability.

    If a client neither supports `documentChanges` nor
    `workspace.workspaceEdit.resourceOperations` then only plain `TextEdit`s
    using the `changes` property are supported.
    """
    documentChanges::Union{Nothing, Vector{Union{TextDocumentEdit, CreateFile, RenameFile, DeleteFile}}} = nothing

    """
    A map of change annotations that can be referenced in
    `AnnotatedTextEdit`s or create, rename and delete file / folder
    operations.

    Whether clients honor this property depends on the client capability
    `workspace.changeAnnotationSupport`.

    # Tags
    - since - 3.16.0
    """
    changeAnnotations::Union{Nothing, Dict{ChangeAnnotationIdentifier, ChangeAnnotation}} = nothing
end

"""
New in version 3.13: [`ResourceOperationKind`](@ref) and [`FailureHandlingKind`](@ref)
and the client capability `workspace.workspaceEdit.resourceOperations` as well as
`workspace.workspaceEdit.failureHandling`.

The capabilities of a workspace edit has evolved over the time. Clients can describe
their support using the following client capability:
"""
@interface WorkspaceEditClientCapabilities begin
    """
    The client supports versioned document changes in `WorkspaceEdit`s
    """
    documentChanges::Union{Nothing, Bool} = nothing

    """
    The resource operations the client supports. Clients should at least
    support 'create', 'rename' and 'delete' files and folders.

    # Tags
    - since - 3.13.0
    """
    resourceOperations::Union{Nothing, Vector{ResourceOperationKind.Ty}} = nothing

    """
    The failure handling strategy of a client if applying the workspace edit
    fails.

    # Tags
    - since - 3.13.0
    """
    failureHandling::Union{Nothing, FailureHandlingKind.Ty} = nothing

    """
    Whether the client normalizes line endings to the client specific
    setting.
    If set to `true` the client will normalize line ending characters
    in a workspace edit to the client specific new line character(s).

    # Tags
    - since - 3.16.0
    """
    normalizesLineEndings::Union{Nothing, Bool} = nothing

    """
    Whether the client in general supports change annotations on text edits,
    create file, rename file and delete file changes.

    # Tags
    - since - 3.16.0
    """
    changeAnnotationSupport::Union{Nothing, @interface begin
        """
        Whether the client groups edits with equal labels into tree nodes,
        for instance all edits labelled with "Changes in Strings" would
        be a tree node.
        """
        groupsOnLabel::Union{Nothing, Bool} = nothing
    end} = nothing
end

# Work Done Progress
# ==================

"""
Work done progress is reported using the generic [`\$/progress` notification](@ref ProgressNotification).
The value payload of a work done progress notification can be of three different forms.
"""
:(work_done_progress)

"""
To start progress reporting a `\$/progress` notification with the following payload must be sent.

# Tags
- since – 3.15.0
"""
@interface WorkDoneProgressBegin begin
    kind::String = "begin"

    """
    Mandatory title of the progress operation. Used to briefly inform about
    the kind of operation being performed.

    Examples: "Indexing" or "Linking dependencies".
    """
    title::String

    """
    Controls if a cancel button should show to allow the user to cancel the
    long running operation. Clients that don't support cancellation are
    allowed to ignore the setting.
    """
    cancellable::Union{Bool, Nothing} = nothing

    """
    Optional, more detailed associated progress message. Contains
    complementary information to the `title`.

    Examples: "3/25 files", "project/src/module2", "node_modules/some_dep".
    If unset, the previous progress message (if any) is still valid.
    """
    message::Union{String, Nothing} = nothing

    """
    Optional progress percentage to display (value 100 is considered 100%).
    If not provided infinite progress is assumed and clients are allowed
    to ignore the `percentage` value in subsequent report notifications.

    The value should be steadily rising. Clients are free to ignore values
    that are not following this rule. The value range is [0, 100].
    """
    percentage::Union{UInt, Nothing} = nothing
end

"""
Reporting progress is done using the following payload.

# Tags
- since – 3.15.0
"""
@interface WorkDoneProgressReport begin
    kind::String = "report"

    """
    Controls enablement state of a cancel button. This property is only valid
    if a cancel button got requested in the `WorkDoneProgressBegin` payload.

    Clients that don't support cancellation or don't support control the
    button's enablement state are allowed to ignore the setting.
    """
    cancellable::Union{Bool, Nothing} = nothing

    """
    Optional, more detailed associated progress message. Contains
    complementary information to the `title`.

    Examples: "3/25 files", "project/src/module2", "node_modules/some_dep".
    If unset, the previous progress message (if any) is still valid.
    """
    message::Union{String, Nothing} = nothing

    """
    Optional progress percentage to display (value 100 is considered 100%).
    If not provided infinite progress is assumed and clients are allowed
    to ignore the `percentage` value in subsequent report notifications.

    The value should be steadily rising. Clients are free to ignore values
    that are not following this rule. The value range is [0, 100].
    """
    percentage::Union{UInt, Nothing} = nothing
end

"""
Signaling the end of a progress reporting is done using the following payload.

# Tags
- since – 3.15.0
"""
@interface WorkDoneProgressEnd begin
    kind::String = "end"

    """
    Optional, a final message indicating to for example indicate the outcome
    of the operation.
    """
    message::Union{String, Nothing} = nothing
end

"""
Union type for all work done progress value types.
"""
const WorkDoneProgressValue = Union{WorkDoneProgressBegin, WorkDoneProgressReport, WorkDoneProgressEnd}
push!(exports, :WorkDoneProgressValue)

@interface WorkDoneProgressParams begin
    "An optional token that a server can use to report work done progress."
    workDoneToken::Union{ProgressToken, Nothing} = nothing
end

@interface WorkDoneProgressOptions begin
    workDoneProgress::Union{Bool, Nothing} = nothing
end

@interface ProgressParams begin
    "The progress token provided by the client or server."
    token::ProgressToken

    "The progress data."
    value::WorkDoneProgressValue
end

"""
The base protocol offers also support to report progress in a generic fashion.
This mechanism can be used to report any kind of progress including [work done progress](@ref work_done_progress)
(usually used to report progress in the user interface using a progress bar) and
[partial result progress](@ref partial_result_progress) to support streaming of results.

Notification:
- method: `\$/progress`
- params: `ProgressParams`

Progress is reported against a token.
The token is different than the request ID which allows to report progress out of band
and also for notification.

# Tags
- since – 3.15.0
"""
@interface ProgressNotification @extends NotificationMessage begin
    method::String = "\$/progress"
    params::ProgressParams
end

# Partial Result Progress
# =======================

"""
Partial results are also reported using the generic [`\$/progress`](@ref work_done_progress) notification.
The value payload of a partial result progress notification is in most cases the same as the final result.
For example the `workspace/symbol` request has `SymbolInformation[]` | `WorkspaceSymbol[]` as the result type.
Partial result is therefore also of type `SymbolInformation[]` | `WorkspaceSymbol[]`.
Whether a client accepts partial result notifications for a request is signaled by adding
a `partialResultToken` to the request parameter.
For example, a `textDocument/reference` request that supports both work done and
partial result progress might look like this:
```json
{
	"textDocument": {
		"uri": "file:///folder/file.ts"
	},
	"position": {
		"line": 9,
		"character": 5
	},
	"context": {
		"includeDeclaration": true
	},
	// The token used to report work done progress.
	"workDoneToken": "1d546990-40a3-4b77-b134-46622995f6ae",
	// The token used to report partial result progress.
	"partialResultToken": "5f6f349e-4f81-4a3b-afff-ee04bff96804"
}
```

The `partialResultToken` is then used to report partial results for the find references request.

If a server reports partial result via a corresponding [`\$/progress`](@ref work_done_progress),
the whole result must be reported using n [`\$/progress`](@ref work_done_progress) notifications.
Each of the n [`\$/progress`](@ref work_done_progress) notification appends items to the result.
The final response has to be empty in terms of result values.
This avoids confusion about how the final result should be interpreted, e.g. as another partial result or as a replacing result.

If the response errors the provided partial results should be treated as follows:
- the `code` equals to `RequestCancelled`: the client is free to use the provided
  results but should make clear that the request got canceled and may be incomplete.
- in all other cases the provided partial results shouldn’t be used.

# Tags
- since – 3.15.0
"""
:(partial_result_progress)

"""
A parameter literal used to pass a partial result token.
"""
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
