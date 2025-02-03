module LSP

using StructTypes

const exports = Set{Symbol}()
const method_dispatcher = Dict{String,DataType}()

include("interface.jl")
include("namespace.jl")

const boolean = Bool
const null = Nothing
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

"""
A general message as defined by JSON-RPC.
The language server protocol always uses “2.0” as the jsonrpc version.
"""
@interface Message begin
    jsonrpc::String = "2.0"
end

"""
A request message to describe a request between the client and the server.
Every processed request must send a response back to the sender of the request.
"""
@interface RequestMessage @extends Message begin
    "The request id."
    id::Int

    "The method to be invoked."
    method::String

    "The method's params."
    params::Union{Any, Nothing} = nothing
end

@namespace ErrorCodes::Int begin
    ParseError = -32700
    InvalidRequest = -32600
    MethodNotFound = -32601
    InvalidParams = -32602
    InternalError = -32603

    """
    This is the start range of JSON-RPC reserved error codes.
    It doesn't denote a real error code. No LSP error codes should be defined between the start
    and end range. For backwards compatibility the `ServerNotInitialized` and the
    `UnknownErrorCode` are left in the range.

    # Tags
    - since – 3.16.0
    """
    jsonrpcReservedErrorRangeStart = -32099
    """
    # Tags
    - deprecated – use jsonrpcReservedErrorRangeStart
    """
    serverErrorStart = -32099

    """
    Error code indicating that a server received a notification or request before the server
    has received the `initialize` request.
    """
    ServerNotInitialized = -32002
    UnknownErrorCode = -32001

    """
    This is the end range of JSON-RPC reserved error codes.
    It doesn't denote a real error code.

    # Tags
    - since – 3.16.0"
    """
    jsonrpcReservedErrorRangeEnd = -32000
    """
    # Tags
    - deprecated – use jsonrpcReservedErrorRangeEnd
    """
    serverErrorEnd = -32000

    """
    This is the start range of LSP reserved error codes.
    It doesn't denote a real error code.

    # Tags
    - since – 3.16.0
    """
    lspReservedErrorRangeStart = -32899

    """
    A request failed but it was syntactically correct, e.g the method name was known and the
    parameters were valid. The error message should contain human readable information about why
    the request failed.

    # Tags
    - since – 3.17.0
    """
    RequestFailed = -32803

    """
    The server cancelled the request. This error code should only be used for requests that
    explicitly support being server cancellable.

    # Tags
    - since – 3.17.0
    """
    ServerCancelled = -32802

    """
    "The server detected that the content of a document got modified outside normal conditions.
    A server should NOT send this error code if it detects a content change in it unprocessed
    messages. The result even computed on an older state might still be useful for the client.
    If a client decides that a result is not of any use anymore the client should cancel the request.
    """
    ContentModified = -32801

    """
    The client has canceled a request and a server has detected the cancel.
    """
    RequestCancelled = -32800

    """
    This is the end range of LSP reserved error codes. It doesn't denote a real error code.

    # Tags
    - since – 3.16.0"
    """
    lspReservedErrorRangeEnd = -32800
end # @namespace ErrorCodes

@interface ResponseError begin
    "A number indicating the error type that occurred."
    code::ErrorCodes.Ty

    "A string providing a short description of the error."
    message::String

    "A primitive or structured value that contains additional information about the error. Can be omitted."
    data::Union{Any, Nothing} = nothing
end

# TODO Revisit this to correctly lower this struct

"""
A Response Message sent as a result of a request.
If a request doesn’t provide a result value the receiver of a request still needs to return
a response message to conform to the JSON-RPC specification.
The result property of the ResponseMessage should be set to null in this case to signal a
successful request.
"""
@interface ResponseMessage @extends Message begin
    "The request id."
    id::Union{Int, Nothing}

    """
    The result of a request. This member is REQUIRED on success.
    This member MUST NOT exist if there was an error invoking the method.
    """
    result::Union{Any, Nothing} = nothing

    "The error object in case a request fails."
    error::Union{ResponseError, Nothing} = nothing
end

"""
A notification message. A processed notification message must not send a response back.
They work like events.
"""
@interface NotificationMessage @extends Message begin
    "The method to be invoked."
    method::String

    "The notification's params."
    params::Union{Any, Nothing} = nothing
end

const DocumentUri = String

const URI = String

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

@interface ClientCapabilities begin
    "Workspace specific client capabilities."
    workspace::Union{Nothing, @anon_interface begin
        """
        The client supports applying batch edits to the workspace by supporting the request
        'workspace/applyEdit'
        """
        applyEdit::Union{Bool, Nothing} = nothing

        """
        The client has support for workspace folders.

        # Tags
        - since – 3.6.0
        """
        workspaceFolders::Union{Bool, Nothing} = nothing

        """
        The client has support for file requests/notifications.

        # Tags
        - since – 3.16.0
        """
        fileOperations::Union{Nothing, @anon_interface begin
            "Whether the client supports dynamic registration for file requests/notifications."
            dynamicRegistration::Union{Bool, Nothing} = nothing

            "The client has support for sending didCreateFiles notifications."
            didCreate::Union{Bool, Nothing} = nothing

            "The client has support for sending willCreateFiles requests."
            willCreate::Union{Bool, Nothing} = nothing

            "The client has support for sending didRenameFiles notifications."
            didRename::Union{Bool, Nothing} = nothing

            "The client has support for sending willRenameFiles requests."
            willRename::Union{Bool, Nothing} = nothing

            "The client has support for sending didDeleteFiles notifications."
            didDelete::Union{Bool, Nothing} = nothing

            "The client has support for sending willDeleteFiles requests."
            willDelete::Union{Bool, Nothing} = nothing
        end} = nothing
    end} = nothing

    "Experimental client capabilities."
    experimental::Union{Any, Nothing} = nothing
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
    clientInfo::Union{Nothing, @anon_interface begin
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
    documentSelector::Union{Vector{DocumentFilter}, Nothing}
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
Diagnostic options.

# Tags
- since – 3.17.0
"""
@interface DiagnosticOptions @extends WorkDoneProgressOptions begin
    "An optional identifier under which the diagnostics are managed by the client."
    identifier::Union{String, Nothing} = nothing

    """
    Whether the language has inter file dependencies meaning that editing code in one file
    can result in a different diagnostic set in another file.
    Inter file dependencies are common for most programming languages and typically uncommon for linters.
    """
    interFileDependencies::Bool

    "The server provides support for workspace diagnostics as well."
    workspaceDiagnostics::Bool
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

"""
Diagnostic registration options.

# Tags
- since – 3.17.0
"""
@interface DiagnosticRegistrationOptions @extends TextDocumentRegistrationOptions,
    DiagnosticOptions, StaticRegistrationOptions begin
end

@interface ServerCapabilities begin
    """
    The position encoding the server picked from the encodings offered by the client via
    the client capability `general.positionEncodings`.

    If the client didn't provide any position encodings the only valid value that a server
    can return is 'utf-16'. If omitted it defaults to 'utf-16'.

    # Tags
    - since – 3.17.0
    """
    positionEncoding::Union{PositionEncodingKind.Ty, Nothing} = nothing

    """
    Defines how text documents are synced. Is either a detailed structure defining each
    notification or for backwards compatibility the TextDocumentSyncKind number.
    If omitted it defaults to `TextDocumentSyncKind.None`.
    """
    textDocumentSync::Union{Union{TextDocumentSyncOptions, TextDocumentSyncKind.Ty}, Nothing} = nothing

    """
    The server has support for pull model diagnostics.

    # Tags
    - since – 3.17.0
    """
    diagnosticProvider::Union{Union{DiagnosticOptions, DiagnosticRegistrationOptions}, Nothing} = nothing

    "Workspace specific server capabilities"
    workspace::Union{Nothing, @anon_interface begin
        """
        The server supports workspace folder.

        # Tags
        - since – 3.6.0
        """
        workspaceFolders::Union{WorkspaceFoldersServerCapabilities, Nothing} = nothing

        """
        The server is interested in file notifications/requests.

        # Tags
        - since – 3.16.0
        """
        fileOperations::Union{Nothing, @anon_interface begin
            "The server is interested in receiving didCreateFiles notifications."
            didCreate::Union{FileOperationRegistrationOptions, Nothing} = nothing

            "The server is interested in receiving willCreateFiles requests."
            willCreate::Union{FileOperationRegistrationOptions, Nothing} = nothing

            "The server is interested in receiving didRenameFiles notifications."
            didRename::Union{FileOperationRegistrationOptions, Nothing} = nothing

            "The server is interested in receiving willRenameFiles requests."
            willRename::Union{FileOperationRegistrationOptions, Nothing} = nothing

            "The server is interested in receiving didDeleteFiles file notifications."
            didDelete::Union{FileOperationRegistrationOptions, Nothing} = nothing

            "The server is interested in receiving willDeleteFiles file requests."
            willDelete::Union{FileOperationRegistrationOptions, Nothing} = nothing
        end}
    end} = nothing
end

@interface InitializeResult begin
    "The capabilities the language server provides."
    capabilities::ServerCapabilities

    """
    Information about the server.

    # Tags
    - since – 3.15.0
    """
    serverInfo::Union{Nothing, @anon_interface begin
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

@interface InitializeResponseError begin
    "A string providing a short description of the error."
    message::String
    code::InitializeErrorCodes.Ty
    data::InitializeError
end

@interface InitializeResponse @extends ResponseMessage begin
    result::Union{InitializeResult, Nothing} = nothing
    error::Union{InitializeResponseError, Nothing} = nothing
end

"""
The document diagnostic report kinds.

# Tags
- since – 3.17.0
"""
@namespace DocumentDiagnosticReportKind::String begin
    "A diagnostic report with a full set of problems."
    Full = "full"

    "A report indicating that the last returned report is still accurate."
    Unchanged = "unchanged"
end

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
Structure to capture a description for an error code.

# Tags
- since – 3.16.0
"""
@interface CodeDescription begin
    "An URI to open with more information about the diagnostic error."
    href::URI
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

    "Deprecated or obsolete code. Clients are allowed to rendered diagnostics with this tag strike through."
    Deprecated = 2
end

"""
Represents a location inside a resource, such as a line inside a text file.
"""
@interface Location begin
    uri::DocumentUri
    range::Range
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

    "A human-readable string describing the source of this diagnostic, e.g. 'typescript' or 'super lint'."
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

"""A diagnostic report with a full set of problems.

# Tags
- since – 3.17.0
"""
@interface FullDocumentDiagnosticReport begin
    "A full document diagnostic report."
    kind::DocumentDiagnosticReportKind.Ty = DocumentDiagnosticReportKind.Full

    "An optional result id. If provided it will be sent on the next diagnostic request for the same document."
    resultId::Union{String, Nothing} = nothing

    "The actual items."
    items::Vector{Diagnostic}
end

"""
"A diagnostic report indicating that the last returned report is still accurate.

# Tags
- since – 3.17.0
"""
@interface UnchangedDocumentDiagnosticReport begin
    "A document diagnostic report indicating no changes to the last result. A server can only return `unchanged` if result ids are provided."
    kind::String = DocumentDiagnosticReportKind.Unchanged

    "A result id which will be sent on the next diagnostic request for the same document."
    resultId::String
end

"""
A full diagnostic report with a set of related documents.

# Tags
- since – 3.17.0
"""
@interface RelatedFullDocumentDiagnosticReport @extends FullDocumentDiagnosticReport begin
    """
    Diagnostics of related documents. This information is useful in programming languages
    where code in a file A can generate diagnostics in a file B which A depends on.
    An example of such a language is C/C++ where macro definitions in a file a.cpp and
    result in errors in a header file b.hpp.

    # Tags
    - since – 3.17.0
    """
    relatedDocuments::Union{Dict{DocumentUri,Union{FullDocumentDiagnosticReport,UnchangedDocumentDiagnosticReport}}, Nothing} = nothing
end

"""
An unchanged diagnostic report with a set of related documents.

# Tags
- since – 3.17.0
"""
@interface RelatedUnchangedDocumentDiagnosticReport @extends UnchangedDocumentDiagnosticReport begin
    """
    Diagnostics of related documents. This information is useful in programming languages
    where code in a file A can generate diagnostics in a file B which A depends on.
    An example of such a language is C/C++ where macro definitions in a file a.cpp and
    result in errors in a header file b.hpp.

    # Tags
    - since – 3.17.0
    """
    relatedDocuments::Union{Dict{DocumentUri,Union{FullDocumentDiagnosticReport,UnchangedDocumentDiagnosticReport}}, Nothing} = nothing
end

"""
Parameters of the document diagnostic request.

# Tags
- since – 3.17.0
"""
@interface DocumentDiagnosticParams @extends WorkDoneProgressParams, PartialResultParams begin
    "The text document."
    textDocument::TextDocumentIdentifier

    "The additional identifier provided during registration."
    identifier::Union{String, Nothing} = nothing

    "The result id of a previous response if provided."
    previousResultId::Union{String, Nothing} = nothing
end

"""
The text document diagnostic request is sent from the client to the server to ask the server
to compute the diagnostics for a given document.
As with other pull requests the server is asked to compute the diagnostics for the currently synced version of the document.
"""
@interface DocumentDiagnosticRequest @extends RequestMessage begin
    method::String = "textDocument/diagnostic"
    params::DocumentDiagnosticParams
end

"""
The result of a document diagnostic pull request.
A report can either be a full report containing all diagnostics for the requested document
or a unchanged report indicating that nothing has changed in terms of diagnostics in
comparison to the last pull request.

# Tags
- since – 3.17.0
"""
const DocumentDiagnosticReport =
    Union{RelatedFullDocumentDiagnosticReport, RelatedUnchangedDocumentDiagnosticReport}

"""
Cancellation data returned from a diagnostic request.

# Tags
- since – 3.17.0
"""
@interface DiagnosticServerCancellationData begin
    retriggerRequest::Bool
end

"""
A full document diagnostic report for a workspace diagnostic result.

# Tags
- since – 3.17.0
"""
@interface WorkspaceFullDocumentDiagnosticReport @extends FullDocumentDiagnosticReport begin
    "The URI for which diagnostic information is reported."
    uri::DocumentUri

    """
    The version number for which the diagnostics are reported.
    If the document is not marked as open `null` can be provided.
    """
    version::Union{Int, Nothing}
end

"""
An unchanged document diagnostic report for a workspace diagnostic result.

# Tags
- since – 3.17.0
"""
@interface WorkspaceUnchangedDocumentDiagnosticReport @extends UnchangedDocumentDiagnosticReport begin
    "The URI for which diagnostic information is reported."
    uri::DocumentUri

    """
    The version number for which the diagnostics are reported.
    If the document is not marked as open `null` can be provided.
    """
    version::Union{Int, Nothing}
end

"""
A workspace diagnostic document report.

# Tags
- since – 3.17.0
"""
const WorkspaceDocumentDiagnosticReport =
    Union{WorkspaceFullDocumentDiagnosticReport, WorkspaceUnchangedDocumentDiagnosticReport}

@interface WorkspaceDiagnosticReport begin
    items::Vector{WorkspaceDocumentDiagnosticReport}
end

"""
A previous result id in a workspace pull request.

# Tags
- since – 3.17.0
"""
@interface PreviousResultId begin
    "The URI for which the client knows a result id."
    uri::DocumentUri

    "The value of the previous result id."
    value::String
end

"""
Parameters of the workspace diagnostic request.

# Tags
- since – 3.17.0
"""
@interface WorkspaceDiagnosticParams @extends WorkDoneProgressParams, PartialResultParams begin
    "The additional identifier provided during registration."
    identifier::Union{String, Nothing} = nothing

    "The currently known diagnostic reports with their\nprevious result ids."
    previousResultIds::Vector{PreviousResultId}
end

@interface WorkspaceDiagnosticRequest @extends RequestMessage begin
    method::String = "workspace/diagnostic"
    params::WorkspaceDiagnosticParams
end

for name in exports
    Core.eval(@__MODULE__, Expr(:export, name))
end

export
    method_dispatcher

end # module LSP
