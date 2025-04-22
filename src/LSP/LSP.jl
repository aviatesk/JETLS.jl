module LSP

using StructTypes

const exports = Set{Symbol}()
const method_dispatcher = Dict{String,DataType}()

include("utils/interface.jl")
include("utils/namespace.jl")

"""
A special object representing `null` value.
When used as a field specified as `StructTypes.omitempties`, the key-value pair is not
omitted in the serialized JSON but instead appears as `null`.
This special object is specifically intended for use in `ResponseMessage`.
"""
struct Null end
const null = Null()
StructTypes.StructType(::Type{Null}) = StructTypes.CustomStruct()
StructTypes.lower(::Null) = nothing
push!(exports, :Null, :null)

const boolean = Bool
# const null = Nothing
const string = String

"""
Defines an integer number in the range of -2^31 to 2^31 - 1.
"""
const integer = Int

"""
Defines an unsigned integer number in the range of 0 to 2^31 - 1.
"""
const uinteger = UInt

@doc """
Defines a decimal number.
Since decimal numbers are very rare in the language server specification we denote the exact
range with every decimal using the mathematics interval notation (e.g. `[0, 1]` denotes all
decimals `d` with `0 <= d <= 1`).
"""
const decimal = Float64

@doc """
The LSP any type

# Tags
- since – 3.17.0
"""
const LSPAny = Any

@doc """
LSP object definition.

# Tags
- since – 3.17.0
"""
const LSPObject = Dict{String,Any}

@doc """
LSP arrays.

# Tags
- since – 3.17.0
"""
const LSPArray = Vector{Any}

const DocumentUri = String

const URI = String


include("messages.jl")

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
    If the character value is greater than the line length it defaults back to the line length.
    """
    character::UInt
end

@interface WorkspaceFolder begin
    "The associated URI for this workspace folder."
    uri::URI

    "The name of the workspace folder. Used to refer to this workspace folder in the user interface."
    name::String
end

"""
The base protocol offers also support to report progress in a generic fashion.
This mechanism can be used to report any kind of progress including work done progress
(usually used to report progress in the user interface using a progress bar) and partial
result progress to support streaming of results.

A progress notification has the following properties:
"""
const ProgressToken = Union{Int, String}

@interface WorkDoneProgressParams begin
    "An optional token that a server can use to report work done progress."
    workDoneToken::Union{ProgressToken, Nothing} = nothing
end

@interface PartialResultParams begin
    "An optional token that a server can use to report partial results (e.g. streaming) to the client."
    partialResultToken::Union{ProgressToken, Nothing} = nothing
end

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
A pattern to describe in which file operation requests or notifications the server is interested in.

# Tags
- since – 3.16.0
"""
@interface FileOperationPattern begin
    """
    The glob pattern to match. Glob patterns can have the following syntax:
    - `*` to match one or more characters in a path segment
    - `?` to match on one character in a path segment
    - `**` to match any number of path segments, including none
    - `{}` to group sub patterns into an OR expression. (e.g. `**\u200b/*.{ts,js}` matches all TypeScript and JavaScript files)
    - `[]` to declare a range of characters to match in a path segment (e.g., `example.[0-9]` to match on `example.0`, `example.1`, …)
    - `[!...]` to negate a range of characters to match in a path segment (e.g., `example.[!0-9]` to match on `example.a`, `example.b`, but not `example.0`)
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

@interface InitializeParams @extends WorkDoneProgressParams begin
    """
    The process Id of the parent process that started the server. Is null if the process has
    not been started by another process. If the parent process is not alive then the server
    should exit (see exit notification) its process.
    """
    processId::Union{Int, Nothing}

    """
    Information about the client

    # Tags
    - since – 3.15.0
    """
    clientInfo::Union{Nothing, @interface begin
        "The name of the client as defined by the client."
        name::String

        "The client's version as defined by the client."
        version::Union{String, Nothing} = nothing
    end} = nothing

    """
    The locale the client is currently showing the user interface in.
    This must not necessarily be the locale of the operating system.

    Uses IETF language tags as the value's syntax (See https://en.wikipedia.org/wiki/IETF_language_tag)

    # Tags
    - since – 3.16.0
    """
    locale::Union{String, Nothing} = nothing

    """
    The rootPath of the workspace. Is null if no folder is open.

    # Tags
    - deprecated – in favour of `rootUri`.
    """
    rootPath::Union{String, Nothing} = nothing

    """
    The rootUri of the workspace. Is null if no folder is open. If both `rootPath` and
    `rootUri` are set `rootUri` wins.

    # Tags
    - deprecated – in favour of `workspaceFolders`
    """
    rootUri::Union{DocumentUri, Nothing}

    "User provided initialization options."
    initializationOptions::Union{Any, Nothing} = nothing

    "The capabilities provided by the client (editor or tool)"
    capabilities::ClientCapabilities

    "The initial trace setting. If omitted trace is disabled ('off')."
    trace::Union{TraceValue.Ty, Nothing} = nothing

    """
    The workspace folders configured in the client when the server starts.
    This property is only available if the client supports workspace folders.
    It can be `null` if the client supports workspace folders but none are configured.

    # Tags
    - since – 3.6.0
    """
    workspaceFolders::Union{Vector{WorkspaceFolder}, Nothing} = nothing
end

"""
The initialize request is sent as the first request from the client to the server.
If the server receives a request or notification before the initialize request it should act as follows:
- For a request the response should be an error with code: -32002. The message can be picked by the server.
- Notifications should be dropped, except for the exit notification. This will allow the exit of a server without an initialize request.

Until the server has responded to the initialize request with an `InitializeResult`,
the client must not send any additional requests or notifications to the server.
In addition the server is not allowed to send any requests or notifications to the client
until it has responded with an `InitializeResult`, with the exception that during the
initialize request the server is allowed to send the notifications `window/showMessage`,
`window/logMessage` and `telemetry/event` as well as the `window/showMessageRequest`
request to the client. In case the client sets up a progress token in the initialize params
(e.g. property `workDoneToken`) the server is also allowed to use that token
(and only that token) using the `\$/progress` notification sent from the server to the client.
The initialize request may only be sent once.
"""
@interface InitializeRequest @extends RequestMessage begin
    method::String = "initialize"
    params::InitializeParams
end

"""
The initialized notification is sent from the client to the server after the client received
the result of the initialize request but before the client is sending any other request or
notification to the server. The server can use the initialized notification, for example,
to dynamically register capabilities. The initialized notification may only be sent once.
"""
@interface InitializedNotification @extends NotificationMessage begin
    method::String = "initialized"
end

@interface ShutdownRequest @extends RequestMessage begin
    method::String = "shutdown"
end

@interface ShutdownResponse @extends ResponseMessage begin
    result::Union{Null, Nothing} = nothing
end

@interface ExitNotification @extends NotificationMessage begin
    method::String = "exit"
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
    Implementation note: these are the same as Unicode code points, so this `PositionEncodingKind`
    may also be used for an encoding-agnostic representation of character offsets.
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

"""
An item to transfer a text document from the client to the server.
"""
@interface TextDocumentItem begin
    "The text document's URI."
    uri::DocumentUri

    "The text document's language identifier."
    languageId::String

    "The version number of this document (it will increase after each change, including undo/redo)."
    version::Int

    "The content of the opened text document."
    text::String
end

"""
Text documents are identified using a URI. On the protocol level, URIs are passed as strings.
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
    - `{}` to group sub patterns into an OR expression. (e.g. `**\u200b/*.{ts,js}` matches all TypeScript and JavaScript files)
    - `[]` to declare a range of characters to match in a path segment (e.g., `example.[0-9]` to match on `example.0`, `example.1`, …)
    - `[!...]` to negate a range of characters to match in a path segment (e.g., `example.[!0-9]` to match on `example.a`, `example.b`, but not `example.0`)
    """
    pattern::Union{String, Nothing} = nothing
end

"""
A document selector is the combination of one or more document filters.
"""
const DocumentSelector = Vector{DocumentFilter}

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

@interface DidOpenTextDocumentParams begin
    "The document that was opened."
    textDocument::TextDocumentItem
end

"""
The document open notification is sent from the client to the server to signal newly opened text documents.
The document’s content is now managed by the client and the server must not try to read the document’s content using the document’s Uri.
Open in this sense means it is managed by the client.
It doesn’t necessarily mean that its content is presented in an editor.
An open notification must not be sent more than once without a corresponding close notification send before.
This means open and close notification must be balanced and the max open count for a particular textDocument is one.
Note that a server’s ability to fulfill requests is independent of whether a text document is open or closed.

The `DidOpenTextDocumentParams` contain the language id the document is associated with.
If the language id of a document changes, the client needs to send a `textDocument/didClose`
to the server followed by a `textDocument/didOpen` with the new language id if the server
handles the new language id as well.
"""
@interface DidOpenTextDocumentNotification @extends NotificationMessage begin
    method::String = "textDocument/didOpen"
    params::DidOpenTextDocumentParams
end

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
    The document that did change.
    The version number points to the version after all provided content changes have been applied.
    """
    textDocument::VersionedTextDocumentIdentifier
    """
    The actual content changes. The content changes describe single state changes to the document.
    So if there are two content changes c1 (at array index 0) and c2 (at array index 1) for
    a document in state S then c1 moves the document from S to S' and c2 from S' to S''.
    So c1 is computed on the state S and c2 is computed on the state S'.

    To mirror the content of a document using change events use the following approach:
    - start with the same initial content
    - apply the 'textDocument/didChange' notifications in the order you receive them.
    - apply the `TextDocumentContentChangeEvent`s in a single notification in the order you receive them.
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

@interface DidCloseTextDocumentParams begin
    "The document that was closed."
    textDocument::TextDocumentIdentifier
end

"""
The document close notification is sent from the client to the server when the document got
closed in the client. The document’s master now exists where the document’s Uri points to
(e.g. if the document’s Uri is a file Uri the master now exists on disk).
As with the open notification the close notification is about managing the document’s content.
Receiving a close notification doesn’t mean that the document was open in an editor before.
A close notification requires a previous open notification to be sent.
Note that a server’s ability to fulfill requests is independent of whether a text document is open or closed.
"""
@interface DidCloseTextDocumentNotification @extends NotificationMessage begin
    method::String = "textDocument/didClose"
    params::DidCloseTextDocumentParams
end

@interface SaveOptions begin
    "The client is supposed to include the content on save."
    includeText::Union{Bool, Nothing} = nothing
end

@interface DidSaveTextDocumentParams begin
    "The document that was saved."
    textDocument::TextDocumentIdentifier
    "Optional the content when saved. Depends on the includeText value when the save notification was requested."
    text::Union{String, Nothing} = nothing
end

@interface DidSaveTextDocumentNotification @extends NotificationMessage begin
    method::String = "textDocument/didSave"
    params::DidSaveTextDocumentParams
end

@interface TextDocumentSyncOptions begin
    "Open and close notifications are sent to the server. If omitted open close notification should not be sent."
    openClose::Union{Bool, Nothing} = nothing
    """
    Change notifications are sent to the server.
    See `TextDocumentSyncKind.None`, `TextDocumentSyncKind.Full` and `TextDocumentSyncKind.Incremental`.
    If omitted it defaults to `TextDocumentSyncKind.None`.
    """
    change::Union{TextDocumentSyncKind.Ty, Nothing} = nothing
    "If present will save notifications are sent to the server. If omitted the notification should not be sent."
    willSave::Union{Bool, Nothing} = nothing
    "If present will save wait until requests are sent to the server. If omitted the request should not be sent."
    willSaveWaitUntil::Union{Bool, Nothing} = nothing
    "If present save notifications are sent to the server. If omitted the notification should not be sent."
    save::Union{Union{Bool, SaveOptions}, Nothing} = nothing
end

@interface WorkDoneProgressOptions begin
    workDoneProgress::Union{Bool, Nothing} = nothing
end

"""
Static registration options to be returned in the initialize request.
"""
@interface StaticRegistrationOptions begin
    """
    The id used to register the request. The id can be used to deregister the request again.
    See also Registration#id.
    """
    id::Union{String, Nothing} = nothing
end

"""
Since version 3.6.0

Many tools support more than one root folder per workspace.
Examples for this are VS Code’s multi-root support, Atom’s project folder support or Sublime’s project support.
If a client workspace consists of multiple roots then a server typically needs to know about this.
The protocol up to now assumes one root folder which is announced to the server by the
`rootUri` property of the `InitializeParams`. If the client supports workspace folders and
announces them via the corresponding `workspaceFolders` client capability,
the `InitializeParams` contain an additional property `workspaceFolders` with the configured
workspace folders when the server starts.

The `workspace/workspaceFolders` request is sent from the server to the client to fetch the
current open list of workspace folders.
Returns null in the response if only a single file is open in the tool.
Returns an empty array if a workspace is open but no folders are configured.
"""
@interface WorkspaceFoldersServerCapabilities begin
    "The server has support for workspace folders"
    supported::Union{Bool, Nothing} = nothing
    """
    Whether the server wants to receive workspace folder change notifications.

    If a string is provided, the string is treated as an ID under which the notification is
    registered on the client side.
    The ID can be used to unregister for these events using the `client/unregisterCapability` request.
    """
    changeNotifications::Union{Union{String, Bool}, Nothing} = nothing
end

@interface InitializeResult begin
    "The capabilities the language server provides."
    capabilities::ServerCapabilities

    """
    Information about the server.

    # Tags
    - since – 3.15.0
    """
    serverInfo::Union{Nothing, @interface begin
        "The name of the server as defined by the server."
        name::String

        "The server's version as defined by the server."
        version::Union{String, Nothing} = nothing
    end} = nothing
end

"Known error codes for an `InitializeErrorCodes`;"
@namespace InitializeErrorCodes::Int begin
    """
    If the protocol version provided by the client can't be handled by the server.

    # Tags
    - deprecated – This initialize error got replaced by client capabilities.
                There is no version handshake in version 3.0x
    """
    unknownProtocolVersion = 1
end

@interface InitializeError begin
    """
    Indicates whether the client execute the following retry logic:
    (1) show the message provided by the ResponseError to the user
    (2) user selects retry or cancel
    (3) if user selected retry the initialize method is sent again.
    """
    retry::Bool
end

@interface InitializeResponseError @extends ResponseError begin
    code::InitializeErrorCodes.Ty
    data::InitializeError
end

@interface InitializeResponse @extends ResponseMessage begin
    result::Union{InitializeResult, Nothing} = nothing
    error::Union{InitializeResponseError, Nothing} = nothing
end

include("diagnostics.jl")

for name in exports
    Core.eval(@__MODULE__, Expr(:export, name))
end

export
    method_dispatcher

end # module LSP
