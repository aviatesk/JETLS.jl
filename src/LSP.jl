@doc """
Defines an integer number in the range of -2^31 to 2^31 - 1.
""" integer

@doc """
Defines an unsigned integer number in the range of 0 to 2^31 - 1.
""" uinteger

@doc """
Defines a decimal number.
Since decimal numbers are very rare in the language server specification we denote the exact
range with every decimal using the mathematics interval notation (e.g. `[0, 1]` denotes all
decimals `d` with `0 <= d <= 1`).
""" decimal

@doc """
The LSP any type

# Tags
- since – 3.17.0
""" LSPAny

@doc """
LSP object definition.

# Tags
- since – 3.17.0
""" LSPObject

@doc """
LSP arrays.

# Tags
- since – 3.17.0
""" LSPArray

"""
A general message as defined by JSON-RPC.
The language server protocol always uses “2.0” as the jsonrpc version.
"""
@kwdef struct Message
    jsonrpc::String = "2.0"
end

"""
A request message to describe a request between the client and the server.
Every processed request must send a response back to the sender of the request.
"""
@kwdef struct RequestMessage
    jsonrpc::String = "2.0"

    "The request id."
    id::Int

    "The method to be invoked."
    method::String

    "The method's params."
    params::Union{Any, Nothing} = nothing
end
StructTypes.omitempties(::Type{RequestMessage}) = (:params,)

@kwdef struct ResponseError
    "A number indicating the error type that occurred."
    code::Int

    "A string providing a short description of the error."
    message::String

    "A primitive or structured value that contains additional\ninformation about the error. Can be omitted."
    data::Union{Any, Nothing} = nothing
end
StructTypes.omitempties(::Type{ResponseError}) = (:data,)

"""
A Response Message sent as a result of a request.
If a request doesn’t provide a result value the receiver of a request still needs to return
a response message to conform to the JSON-RPC specification.
The result property of the ResponseMessage should be set to null in this case to signal a
successful request.
"""
@kwdef struct ResponseMessage
    jsonrpc::String = "2.0"

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
StructTypes.omitempties(::Type{ResponseMessage}) = (:result, :error)

module ErrorCodes
const ParseError = -32700
const InvalidRequest = -32600
const MethodNotFound = -32601
const InvalidParams = -32602
const InternalError = -32603
"""
This is the start range of JSON-RPC reserved error codes.
It doesn't denote a real error code. No LSP error codes should be defined between the start
and end range. For backwards compatibility the `ServerNotInitialized` and the
`UnknownErrorCode` are left in the range.

# Tags
- since – 3.16.0
"""
const jsonrpcReservedErrorRangeStart = -32099
"""
# Tags
- deprecated – use jsonrpcReservedErrorRangeStart
"""
const serverErrorStart = -32099
"""
Error code indicating that a server received a notification or request before the server
has received the `initialize` request.
"""
const ServerNotInitialized = -32002
const UnknownErrorCode = -32001
"""
This is the end range of JSON-RPC reserved error codes.
It doesn't denote a real error code.

# Tags
- since – 3.16.0"
"""
const jsonrpcReservedErrorRangeEnd = -32000
"""
# Tags
- deprecated – use jsonrpcReservedErrorRangeEnd
"""
const serverErrorEnd = -32000
"""
This is the start range of LSP reserved error codes.
It doesn't denote a real error code.

# Tags
- since – 3.16.0
"""
const lspReservedErrorRangeStart = -32899
"""
A request failed but it was syntactically correct, e.g the method name was known and the
parameters were valid. The error message should contain human readable information about why
the request failed.

# Tags
- since – 3.17.0
"""
const RequestFailed = -32803
"""
The server cancelled the request. This error code should\nonly be used for requests that
explicitly support being server cancellable.

# Tags
- since – 3.17.0
"""
const ServerCancelled = -32802
"""
"The server detected that the content of a document got modified outside normal conditions.
A server should NOT send this error code if it detects a content change in it unprocessed
messages. The result even computed on an older state might still be useful for the client.
If a client decides that a result is not of any use anymore the client should cancel the request.
"""
const ContentModified = -32801
"""
The client has canceled a request and a server has detected the cancel.
"""
const RequestCancelled = -32800
"""
This is the end range of LSP reserved error codes. It doesn't denote a real error code.

# Tags
- since – 3.16.0"
"""
const lspReservedErrorRangeEnd = -32800
end # module ErrorCodes

"""
A notification message. A processed notification message must not send a response back.
They work like events.
"""
@kwdef struct NotificationMessage
    jsonrpc::String = "2.0"

    "The method to be invoked."
    method::String

    "The notification's params."
    params::Union{Any, Nothing} = nothing
end
StructTypes.omitempties(::Type{NotificationMessage}) = (:params,)

lsptypeof(::Val{:DocumentUri}) = String
lsptypeof(::Val{:URI}) = String

"""
Position in a text document expressed as zero-based line and zero-based character offset.
A position is between two characters like an ‘insert’ cursor in an editor.
Special values like for example -1 to denote the end of a line are not supported.
"""
@kwdef struct Position
    "Line position in a document (zero-based)."
    line::UInt

    """
    Character offset on a line in a document (zero-based). The meaning of this offset is
    determined by the negotiated `PositionEncodingKind`.
    If the character value is greater than the line length it defaults back to the line length.
    """
    character::UInt
end

@kwdef struct WorkspaceFolder
    "The associated URI for this workspace folder."
    uri::lsptypeof(Val(:URI))

    "The name of the workspace folder. Used to refer to this\nworkspace folder in the user interface."
    name::String
end

"""
The base protocol offers also support to report progress in a generic fashion.
This mechanism can be used to report any kind of progress including work done progress
(usually used to report progress in the user interface using a progress bar) and partial
result progress to support streaming of results.

A progress notification has the following properties:
"""
ProgressToken
lsptypeof(::Val{:ProgressToken}) = Union{Int, String}

@kwdef struct WorkDoneProgressParams
    "An optional token that a server can use to report work done progress."
    workDoneToken::Union{lsptypeof(Val(:ProgressToken)), Nothing} = nothing
end
StructTypes.omitempties(::Type{WorkDoneProgressParams}) = (:workDoneToken,)

@kwdef struct PartialResultParams
    "An optional token that a server can use to report partial results (e.g. streaming) to the client."
    partialResultToken::Union{lsptypeof(Val(:ProgressToken)), Nothing} = nothing
end
StructTypes.omitempties(::Type{PartialResultParams}) = (:partialResultToken,)

"""
A TraceValue represents the level of verbosity with which the server systematically reports
its execution trace using \$/logTrace notifications. The initial trace value is set by the
client at initialization and can be modified later using the \$/setTrace notification.
"""
module TraceValue
const off = "off"
const messages = "messages"
const verbose = "verbose"
end # TraceValue
lsptypeof(::Val{:TraceValue}) = String

@kwdef struct ClientFileOperations
    "Whether the client supports dynamic registration for file\nrequests/notifications."
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
end
StructTypes.omitempties(::Type{ClientFileOperations}) = (:dynamicRegistration, :didCreate, :willCreate, :didRename, :willRename, :didDelete, :willDelete)
Base.convert(::Type{ClientFileOperations}, nt::NamedTuple) = ClientFileOperations(; nt...)

@kwdef struct ClientWorkspaceCapabilities
    """
    The client supports applying batch edits\nto the workspace by supporting the request
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
    ClientFileOperations::Union{ClientFileOperations, Nothing} = nothing
end
StructTypes.omitempties(::Type{ClientWorkspaceCapabilities}) = (:applyEdit, :workspaceFolders, :ClientFileOperations)
Base.convert(::Type{ClientWorkspaceCapabilities}, nt::NamedTuple) = ClientWorkspaceCapabilities(; nt...)

@kwdef struct ClientCapabilities
    "Workspace specific client capabilities."
    workspace::Union{ClientWorkspaceCapabilities, Nothing} = nothing
    "Experimental client capabilities."
    experimental::Union{Any, Nothing} = nothing
end
StructTypes.omitempties(::Type{ClientCapabilities}) = (:workspace, :experimental)

"""
A pattern kind describing if a glob pattern matches a file a folder or both.

# Tags
- since – 3.16.0
"""
module FileOperationPatternKind
"""The pattern matches a file only."""
const file = "file"
"""The pattern matches a folder only."""
const folder = "folder"
end
lsptypeof(::Val{:FileOperationPatternKind}) = String

"""
Matching options for the file operation pattern.

# Tags
- since – 3.16.0
"""
@kwdef struct FileOperationPatternOptions
    "The pattern should be matched ignoring casing."
    ignoreCase::Union{Bool, Nothing} = nothing
end
StructTypes.omitempties(::Type{FileOperationPatternOptions}) = (:ignoreCase,)

"""
A pattern to describe in which file operation requests or notifications the server is interested in.

# Tags
- since – 3.16.0
"""
@kwdef struct FileOperationPattern
    """
    The glob pattern to match. Glob patterns can have the following syntax:
    - `*` to match one or more characters in a path segment
    - `?` to match on one character in a path segment
    - `**` to match any number of path segments, including none
    - `{}` to group sub patterns into an OR expression. (e.g. `**\u200b/*.{ts,js}`\n  matches all TypeScript and JavaScript files)
    - `[]` to declare a range of characters to match in a path segment (e.g., `example.[0-9]` to match on `example.0`, `example.1`, …)
    - `[!...]` to negate a range of characters to match in a path segment (e.g., `example.[!0-9]` to match on `example.a`, `example.b`, but not `example.0`)
    """
    glob::String
    "Whether to match files or folders with this pattern. Matches both if undefined."
    matches::Union{lsptypeof(Val(:FileOperationPatternKind)), Nothing} = nothing
    "Additional options used during matching."
    options::Union{FileOperationPatternOptions, Nothing} = nothing
end
StructTypes.omitempties(::Type{FileOperationPattern}) = (:matches, :options)

"""
A filter to describe in which file operation requests or notifications the server is
interested in.

# Tags
- since – 3.16.0
"""
@kwdef struct FileOperationFilter
    "A Uri like `file` or `untitled`."
    scheme::Union{String, Nothing} = nothing
    "The actual file operation pattern."
    pattern::FileOperationPattern
end
StructTypes.omitempties(::Type{FileOperationFilter}) = (:scheme,)

"""
The options to register for file operations.

# Tags
- since – 3.16.0
"""
@kwdef struct FileOperationRegistrationOptions
    "The actual filters."
    filters::Vector{FileOperationFilter}
end

@kwdef struct ClientInfo
    "The name of the client as defined by the client."
    name::String
    "The client's version as defined by the client."
    version::Union{String, Nothing} = nothing
end
StructTypes.omitempties(::Type{ClientInfo}) = (:version,)
Base.convert(::Type{ClientInfo}, nt::NamedTuple) = ClientInfo(; nt...)
@kwdef struct InitializeParams
    "An optional token that a server can use to report work done progress."
    workDoneToken::Union{lsptypeof(Val(:ProgressToken)), Nothing} = nothing
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
    clientInfo::Union{ClientInfo, Nothing} = nothing
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
    rootUri::Union{lsptypeof(Val(:DocumentUri)), Nothing}
    "User provided initialization options."
    initializationOptions::Union{Any, Nothing} = nothing
    "The capabilities provided by the client (editor or tool)"
    capabilities::ClientCapabilities
    "The initial trace setting. If omitted trace is disabled ('off')."
    trace::Union{lsptypeof(Val(:TraceValue)), Nothing} = nothing
    """
    The workspace folders configured in the client when the server starts.
    This property is only available if the client supports workspace folders.
    It can be `null` if the client supports workspace folders but none are configured.

    # Tags
    - since – 3.6.0
    """
    workspaceFolders::Union{Vector{WorkspaceFolder}, Nothing} = nothing
end
StructTypes.omitempties(::Type{InitializeParams}) =
    (:workDoneToken, :clientInfo, :locale, :rootPath, :initializationOptions, :trace, :workspaceFolders)

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
@kwdef struct InitializeRequest
    jsonrpc::String = "2.0"
    "The request id."
    id::Int
    method::String = "initialize"
    params::InitializeParams
end

"""
The initialized notification is sent from the client to the server after the client received
the result of the initialize request but before the client is sending any other request or
notification to the server. The server can use the initialized notification, for example,
to dynamically register capabilities. The initialized notification may only be sent once.
"""
@kwdef struct InitializedNotification
    jsonrpc::String = "2.0"
    "The notification's params."
    params::Union{Any, Nothing} = nothing
    method::String = "initialized"
end
StructTypes.omitempties(::Type{InitializedNotification}) = (:params,)

@kwdef struct ShutdownRequest
    jsonrpc::String = "2.0"
    "The request id."
    id::Int
    "The method's params."
    params::Union{Any, Nothing} = nothing
    method::String = "shutdown"
end
StructTypes.omitempties(::Type{ShutdownRequest}) = (:params,)

@kwdef struct ExitNotification
    jsonrpc::String = "2.0"
    "The notification's params."
    params::Union{Any, Nothing} = nothing
    method::String = "exit"
end
StructTypes.omitempties(::Type{ExitNotification}) = (:params,)

lsptypeof(::Val{:PositionEncodingKind}) = String

"""
A type indicating how positions are encoded, specifically what column offsets mean.

# Tags
- since – 3.17.0
"""
module PositionEncodingKind
"""
Character offsets count UTF-8 code units (e.g bytes).
"""
const UTF8 = "utf-8"
"""
Character offsets count UTF-16 code units.
This is the default and must always be supported by servers.
"""
const UTF16 = "utf-16"
"""
Character offsets count UTF-32 code units.
Implementation note: these are the same as Unicode code points, so this `PositionEncodingKind`
may also be used for an encoding-agnostic representation of character offsets.
"""
const UTF32 = "utf-32"
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
@kwdef struct Range
    "The range's start position."
    start::Position
    "The range's end position."
    var"end"::Position
end

"""
An item to transfer a text document from the client to the server.
"""
@kwdef struct TextDocumentItem
    "The text document's URI."
    uri::lsptypeof(Val(:DocumentUri))
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
@kwdef struct TextDocumentIdentifier
    "The text document's URI."
    uri::lsptypeof(Val(:DocumentUri))
end

"""
An identifier to denote a specific version of a text document.
This information usually flows from the client to the server.
"""
@kwdef struct VersionedTextDocumentIdentifier
    "The text document's URI."
    uri::lsptypeof(Val(:DocumentUri))
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
@kwdef struct OptionalVersionedTextDocumentIdentifier
    "The text document's URI."
    uri::lsptypeof(Val(:DocumentUri))
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
module TextDocumentSyncKind
"Documents should not be synced at all."
const None = 0
"Documents are synced by always sending the full content of the document."
const Full = 1
"""
Documents are synced by sending the full content on open.
After that only incremental updates to the document are sent.
"""
const Incremental = 2
end
lsptypeof(::Val{:TextDocumentSyncKind}) = Int

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
@kwdef struct DocumentFilter
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
    - `{}` to group sub patterns into an OR expression. (e.g. `**\u200b/*.{ts,js}`\n  matches all TypeScript and JavaScript files)
    - `[]` to declare a range of characters to match in a path segment (e.g., `example.[0-9]` to match on `example.0`, `example.1`, …)
    - `[!...]` to negate a range of characters to match in a path segment (e.g., `example.[!0-9]` to match on `example.a`, `example.b`, but not `example.0`)
    """
    pattern::Union{String, Nothing} = nothing
end
StructTypes.omitempties(::Type{DocumentFilter}) = (:language, :scheme, :pattern)

"""
A document selector is the combination of one or more document filters.
"""
const DocumentSelector = Vector{DocumentFilter}

"""
General text document registration options.
"""
@kwdef struct TextDocumentRegistrationOptions
    """
    A document selector to identify the scope of the registration.
    If set to null the document selector provided on the client side will be used.
    """
    documentSelector::Union{Vector{DocumentFilter}, Nothing}
end

@kwdef struct DidOpenTextDocumentParams
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
to the server followed by a `textDocument/didOpen` with the new language id if the server handles the new language id as well.
"""
@kwdef struct DidOpenTextDocumentNotification
    jsonrpc::String = "2.0"
    method::String = "textDocument/didOpen"
    params::DidOpenTextDocumentParams
end

"""
Describe options to be used when registering for text document change events.
"""
@kwdef struct TextDocumentChangeRegistrationOptions
    """
    A document selector to identify the scope of the registration.
    If set to null the document selector provided on the client side will be used.
    """
    documentSelector::Union{Vector{DocumentFilter}, Nothing}
    """
    How documents are synced to the server.
    See `TextDocumentSyncKind.Full` and `TextDocumentSyncKind.Incremental`.
    """
    syncKind::lsptypeof(Val(:TextDocumentSyncKind))
end

"""
An event describing a change to a text document.
If only a text is provided it is considered to be the full content of the document.
"""
@kwdef struct TextDocumentContentChangeEvent
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
StructTypes.omitempties(::Type{TextDocumentContentChangeEvent}) = (:range, :rangeLength)

@kwdef struct DidChangeTextDocumentParams
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
@kwdef struct DidChangeTextDocumentNotification
    jsonrpc::String = "2.0"
    method::String = "textDocument/didChange"
    params::DidChangeTextDocumentParams
end

@kwdef struct DidCloseTextDocumentParams
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
@kwdef struct DidCloseTextDocumentNotification
    jsonrpc::String = "2.0"
    method::String = "textDocument/didClose"
    params::DidCloseTextDocumentParams
end

@kwdef struct SaveOptions
    "The client is supposed to include the content on save."
    includeText::Union{Bool, Nothing} = nothing
end
StructTypes.omitempties(::Type{SaveOptions}) = (:includeText,)

@kwdef struct DidSaveTextDocumentParams
    "The document that was saved."
    textDocument::TextDocumentIdentifier
    "Optional the content when saved. Depends on the includeText value when the save notification was requested."
    text::Union{String, Nothing} = nothing
end
StructTypes.omitempties(::Type{DidSaveTextDocumentParams}) = (:text,)

@kwdef struct DidSaveTextDocumentNotification
    jsonrpc::String = "2.0"
    method::String = "textDocument/didSave"
    params::DidSaveTextDocumentParams
end

@kwdef struct TextDocumentSyncOptions
    "Open and close notifications are sent to the server. If omitted open close notification should not be sent."
    openClose::Union{Bool, Nothing} = nothing
    """
    Change notifications are sent to the server.
    See `TextDocumentSyncKind.None`, `TextDocumentSyncKind.Full` and `TextDocumentSyncKind.Incremental`.
    If omitted it defaults to `TextDocumentSyncKind.None`.
    """
    change::Union{lsptypeof(Val(:TextDocumentSyncKind)), Nothing} = nothing
    "If present will save notifications are sent to the server. If omitted the notification should not be sent."
    willSave::Union{Bool, Nothing} = nothing
    "If present will save wait until requests are sent to the server. If omitted the request should not be sent."
    willSaveWaitUntil::Union{Bool, Nothing} = nothing
    "If present save notifications are sent to the server. If omitted the notification should not be sent."
    save::Union{Union{Bool, SaveOptions}, Nothing} = nothing
end
StructTypes.omitempties(::Type{TextDocumentSyncOptions}) = (:openClose, :change, :willSave, :willSaveWaitUntil, :save)

@kwdef struct WorkDoneProgressOptions
    workDoneProgress::Union{Bool, Nothing} = nothing
end
StructTypes.omitempties(::Type{WorkDoneProgressOptions}) = (:workDoneProgress,)

"""
Diagnostic options.

# Tags
- since – 3.17.0
"""
@kwdef struct DiagnosticOptions
    workDoneProgress::Union{Bool, Nothing} = nothing
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
StructTypes.omitempties(::Type{DiagnosticOptions}) = (:workDoneProgress, :identifier)

"""
Static registration options to be returned in the initialize request.
"""
@kwdef struct StaticRegistrationOptions
    "The id used to register the request. The id can be used to deregister the request again. See also Registration#id."
    id::Union{String, Nothing} = nothing
end
StructTypes.omitempties(::Type{StaticRegistrationOptions}) = (:id,)

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
@kwdef struct WorkspaceFoldersServerCapabilities
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
StructTypes.omitempties(::Type{WorkspaceFoldersServerCapabilities}) = (:supported, :changeNotifications)

"""
Diagnostic registration options.

# Tags
- since – 3.17.0
"""
@kwdef struct DiagnosticRegistrationOptions
    "A document selector to identify the scope of the registration. If set to null the document selector provided on the client side will be used."
    documentSelector::Union{Vector{DocumentFilter}, Nothing}
    workDoneProgress::Union{Bool, Nothing} = nothing
    "An optional identifier under which the diagnostics are managed by the client."
    identifier::Union{String, Nothing} = nothing
    """
    Whether the language has inter file dependencies meaning that editing code in one file
    can result in a different diagnostic set in another file. Inter file dependencies are
    common for most programming languages and typically uncommon for linters.
    """
    interFileDependencies::Bool
    "The server provides support for workspace diagnostics as well."
    workspaceDiagnostics::Bool
    "The id used to register the request. The id can be used to deregister the request again. See also Registration#id."
    id::Union{String, Nothing} = nothing
end
StructTypes.omitempties(::Type{DiagnosticRegistrationOptions}) = (:workDoneProgress, :identifier, :id)

@kwdef struct ServerFileOperations
    "The server is interested in receiving didCreateFiles\nnotifications."
    didCreate::Union{FileOperationRegistrationOptions, Nothing} = nothing
    "The server is interested in receiving willCreateFiles requests."
    willCreate::Union{FileOperationRegistrationOptions, Nothing} = nothing
    "The server is interested in receiving didRenameFiles\nnotifications."
    didRename::Union{FileOperationRegistrationOptions, Nothing} = nothing
    "The server is interested in receiving willRenameFiles requests."
    willRename::Union{FileOperationRegistrationOptions, Nothing} = nothing
    "The server is interested in receiving didDeleteFiles file\nnotifications."
    didDelete::Union{FileOperationRegistrationOptions, Nothing} = nothing
    "The server is interested in receiving willDeleteFiles file\nrequests."
    willDelete::Union{FileOperationRegistrationOptions, Nothing} = nothing
end
StructTypes.omitempties(::Type{ServerFileOperations}) = (:didCreate, :willCreate, :didRename, :willRename, :didDelete, :willDelete)
Base.convert(::Type{ServerFileOperations}, nt::NamedTuple) = ServerFileOperations(; nt...)

@kwdef struct WorkspaceServerCapabilities
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
    ClientFileOperations::Union{ServerFileOperations, Nothing} = nothing
end
StructTypes.omitempties(::Type{WorkspaceServerCapabilities}) = (:workspaceFolders, :ClientFileOperations)
Base.convert(::Type{WorkspaceServerCapabilities}, nt::NamedTuple) = WorkspaceServerCapabilities(; nt...)

@kwdef struct ServerCapabilities
    """
    The position encoding the server picked from the encodings offered by the client via
    the client capability `general.positionEncodings`.

    If the client didn't provide any position encodings the only valid value that a server
    can return is 'utf-16'. If omitted it defaults to 'utf-16'.

    # Tags
    - since – 3.17.0
    """
    positionEncoding::Union{lsptypeof(Val(:PositionEncodingKind)), Nothing} = nothing
    """
    Defines how text documents are synced. Is either a detailed structure defining each
    notification or for backwards compatibility the TextDocumentSyncKind number.
    If omitted it defaults to `TextDocumentSyncKind.None`.
    """
    textDocumentSync::Union{Union{TextDocumentSyncOptions, lsptypeof(Val(:TextDocumentSyncKind))}, Nothing} = nothing
    """
    The server has support for pull model diagnostics.

    # Tags
    - since – 3.17.0
    """
    diagnosticProvider::Union{Union{DiagnosticOptions, DiagnosticRegistrationOptions}, Nothing} = nothing
    "Workspace specific server capabilities"
    workspace::Union{WorkspaceServerCapabilities, Nothing} = nothing
end
StructTypes.omitempties(::Type{ServerCapabilities}) =
    (:positionEncoding, :textDocumentSync, :diagnosticProvider, :workspace)

@kwdef struct ServerInfo
    "The name of the server as defined by the server."
    name::String
    "The server's version as defined by the server."
    version::Union{String, Nothing} = nothing
end
StructTypes.omitempties(::Type{ServerInfo}) = (:version,)
Base.convert(::Type{ServerInfo}, nt::NamedTuple) = ServerInfo(; nt...)

@kwdef struct InitializeResult
    "The capabilities the language server provides."
    capabilities::ServerCapabilities
    """
    Information about the server.

    # Tags
    - since – 3.15.0
    """
    serverInfo::Union{ServerInfo, Nothing} = nothing
end
StructTypes.omitempties(::Type{InitializeResult}) = (:serverInfo,)

"Known error codes for an `InitializeErrorCodes`;"
module InitializeErrorCodes
"""
If the protocol version provided by the client can't be handled by the server.

# Tags
- deprecated – This initialize error got replaced by client capabilities.
               There is no version handshake in version 3.0x
"""
const unknownProtocolVersion = 1
end
lsptypeof(::Val{:InitializeErrorCodes}) = Int

@kwdef struct InitializeError
    """
    Indicates whether the client execute the following retry logic:
    (1) show the message provided by the ResponseError to the user
    (2) user selects retry or cancel
    (3) if user selected retry the initialize method is sent again.
    """
    retry::Bool
end

@kwdef struct InitializeResponseError
    "A string providing a short description of the error."
    message::String
    code::lsptypeof(Val(:InitializeErrorCodes))
    data::InitializeError
end

@kwdef struct InitializeResponse
    jsonrpc::String = "2.0"
    "The request id."
    id::Union{Int, Nothing}
    result::Union{InitializeResult, Nothing} = nothing
    error::Union{InitializeResponseError, Nothing} = nothing
end
StructTypes.omitempties(::Type{InitializeResponse}) = (:result, :error)

"""
The document diagnostic report kinds.

# Tags
- since – 3.17.0
"""
module DocumentDiagnosticReportKind
"A diagnostic report with a full set of problems."
const Full = "full"
"A report indicating that the last returned report is still accurate."
const Unchanged = "unchanged"
end
lsptypeof(::Val{:DocumentDiagnosticReportKind}) = String

module DiagnosticSeverity
"Reports an error."
const Error = 1
"Reports a warning."
const Warning = 2
"Reports an information."
const Information = 3
"Reports a hint."
const Hint = 4
end
lsptypeof(::Val{:DiagnosticSeverity}) = Int

"""
Structure to capture a description for an error code.

# Tags
- since – 3.16.0
"""
@kwdef struct CodeDescription
    "An URI to open with more information about the diagnostic error."
    href::lsptypeof(Val(:URI))
end

"""
The diagnostic tags.

# Tags
- since – 3.15.0
"""
module DiagnosticTag
const Unnecessary = 1
@doc "Unused or unnecessary code.\n\nClients are allowed to render diagnostics with this tag faded out\ninstead of having an error squiggle." Unnecessary
const Deprecated = 2
@doc "Deprecated or obsolete code.\n\nClients are allowed to rendered diagnostics with this tag strike through." Deprecated
end
lsptypeof(::Val{:DiagnosticTag}) = Int

"""
Represents a location inside a resource, such as a line inside a text file.
"""
@kwdef struct Location
    uri::lsptypeof(Val(:DocumentUri))
    range::Range
end

"""
Represents a related message and source code location for a diagnostic.
This should be used to point to code locations that cause or are related to a diagnostics,
e.g when duplicating a symbol in a scope.
"""
@kwdef struct DiagnosticRelatedInformation
    "The location of this related diagnostic information."
    location::Location
    "The message of this related diagnostic information."
    message::String
end

@kwdef struct Diagnostic
    "The range at which the message applies."
    range::Range
    """
    The diagnostic's severity.
    To avoid interpretation mismatches when a server is used with different clients it is
    highly recommended that servers always provide a severity value.
    If omitted, it’s recommended for the client to interpret it as an Error severity.
    """
    severity::Union{lsptypeof(Val(:DiagnosticSeverity)), Nothing} = nothing
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
    tags::Union{Vector{lsptypeof(Val(:DiagnosticTag))}, Nothing} = nothing
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
StructTypes.omitempties(::Type{Diagnostic}) =
    (:severity, :code, :codeDescription, :source, :tags, :relatedInformation, :data)

"""A diagnostic report with a full set of problems.

# Tags
- since – 3.17.0
"""
@kwdef struct FullDocumentDiagnosticReport
    "A full document diagnostic report."
    kind::lsptypeof(Val(:DocumentDiagnosticReportKind))
    "An optional result id. If provided it will be sent on the next diagnostic request for the same document."
    resultId::Union{String, Nothing} = nothing
    "The actual items."
    items::Vector{Diagnostic}
end
StructTypes.omitempties(::Type{FullDocumentDiagnosticReport}) = (:resultId,)

"""
"A diagnostic report indicating that the last returned report is still accurate.

# Tags
- since – 3.17.0
"""
@kwdef struct UnchangedDocumentDiagnosticReport
    "A document diagnostic report indicating no changes to the last result. A server can only return `unchanged` if result ids are provided."
    kind::lsptypeof(Val(:DocumentDiagnosticReportKind))
    "A result id which will be sent on the next diagnostic request for the same document."
    resultId::String
end

"""
A full diagnostic report with a set of related documents.

# Tags
- since – 3.17.0
"""
@kwdef struct RelatedFullDocumentDiagnosticReport
    "A full document diagnostic report."
    kind::lsptypeof(Val(:DocumentDiagnosticReportKind))
    "An optional result id. If provided it will\nbe sent on the next diagnostic request for the same document."
    resultId::Union{String, Nothing} = nothing
    "The actual items."
    items::Vector{Diagnostic}
    """
    Diagnostics of related documents. This information is useful in programming languages
    where code in a file A can generate diagnostics in a file B which A depends on.
    An example of such a language is C/C++ where macro definitions in a file a.cpp and
    result in errors in a header file b.hpp.

    # Tags
    - since – 3.17.0
    """
    relatedDocuments::Union{Vector{Dict{lsptypeof(Val(:DocumentUri)),Union{FullDocumentDiagnosticReport,UnchangedDocumentDiagnosticReport}}}, Nothing} = nothing
end
StructTypes.omitempties(::Type{RelatedFullDocumentDiagnosticReport}) = (:resultId, :relatedDocuments)

"""
An unchanged diagnostic report with a set of related documents.

# Tags
- since – 3.17.0
"""
@kwdef struct RelatedUnchangedDocumentDiagnosticReport
    """
    A document diagnostic report indicating\nno changes to the last result.
    A server can only return `unchanged` if result ids are provided.
    """
    kind::lsptypeof(Val(:DocumentDiagnosticReportKind))
    "A result id which will be sent on the next diagnostic request for the same document."
    resultId::String
    """
    Diagnostics of related documents. This information is useful in programming languages
    where code in a file A can generate diagnostics in a file B which A depends on.
    An example of such a language is C/C++ where macro definitions in a file a.cpp and
    result in errors in a header file b.hpp.

    # Tags
    - since – 3.17.0
    """
    relatedDocuments::Union{Vector{Dict{lsptypeof(Val(:DocumentUri)),Union{FullDocumentDiagnosticReport,UnchangedDocumentDiagnosticReport}}}, Nothing} = nothing
end
StructTypes.omitempties(::Type{RelatedUnchangedDocumentDiagnosticReport}) = (:relatedDocuments,)

"""
A full document diagnostic report for a workspace diagnostic result.

# Tags
- since – 3.17.0
"""
@kwdef struct WorkspaceFullDocumentDiagnosticReport
    "A full document diagnostic report."
    kind::lsptypeof(Val(:DocumentDiagnosticReportKind))
    "An optional result id. If provided it will be sent on the next diagnostic request for the same document."
    resultId::Union{String, Nothing} = nothing
    "The actual items."
    items::Vector{Diagnostic}
    "The URI for which diagnostic information is reported."
    uri::lsptypeof(Val(:DocumentUri))
    "The version number for which the diagnostics are reported. If the document is not marked as open `null` can be provided."
    version::Union{Int, Nothing}
end
StructTypes.omitempties(::Type{WorkspaceFullDocumentDiagnosticReport}) = (:resultId,)

"""
An unchanged document diagnostic report for a workspace diagnostic result.

# Tags
- since – 3.17.0
"""
@kwdef struct WorkspaceUnchangedDocumentDiagnosticReport
    "A document diagnostic report indicating no changes to the last result. A server can only return `unchanged` if result ids are provided."
    kind::lsptypeof(Val(:DocumentDiagnosticReportKind))
    "A result id which will be sent on the next\ndiagnostic request for the same document."
    resultId::String
    "The URI for which diagnostic information is reported."
    uri::lsptypeof(Val(:DocumentUri))
    "The version number for which the diagnostics are reported. If the document is not marked as open `null` can be provided."
    version::Union{Int, Nothing}
end

"""
A workspace diagnostic document report.

# Tags
- since – 3.17.0
"""
const WorkspaceDocumentDiagnosticReport =
    Union{WorkspaceFullDocumentDiagnosticReport, WorkspaceUnchangedDocumentDiagnosticReport}

@kwdef struct WorkspaceDiagnosticReport
    items::Vector{WorkspaceDocumentDiagnosticReport}
end

"""
A previous result id in a workspace pull request.

# Tags
- since – 3.17.0
"""
@kwdef struct PreviousResultId
    "The URI for which the client knows a\nresult id."
    uri::lsptypeof(Val(:DocumentUri))
    "The value of the previous result id."
    value::String
end

"""
Parameters of the workspace diagnostic request.

# Tags
- since – 3.17.0
"""
@kwdef struct WorkspaceDiagnosticParams
    "An optional token that a server can use to report work done progress."
    workDoneToken::Union{lsptypeof(Val(:ProgressToken)), Nothing} = nothing
    "An optional token that a server can use to report partial results (e.g.\nstreaming) to the client."
    partialResultToken::Union{lsptypeof(Val(:ProgressToken)), Nothing} = nothing
    "The additional identifier provided during registration."
    identifier::Union{String, Nothing} = nothing
    "The currently known diagnostic reports with their\nprevious result ids."
    previousResultIds::Vector{PreviousResultId}
end
StructTypes.omitempties(::Type{WorkspaceDiagnosticParams}) =
    (:workDoneToken, :partialResultToken, :identifier)

@kwdef struct WorkspaceDiagnosticRequest
    jsonrpc::String = "2.0"
    "The request id."
    id::Int
    method::String = "workspace/diagnostic"
    params::WorkspaceDiagnosticParams
end

"""
Parameters of the document diagnostic request.

# Tags
- since – 3.17.0
"""
@kwdef struct DocumentDiagnosticParams
    "An optional token that a server can use to report work done progress."
    workDoneToken::Union{lsptypeof(Val(:ProgressToken)), Nothing} = nothing
    "An optional token that a server can use to report partial results (e.g. streaming) to the client."
    partialResultToken::Union{lsptypeof(Val(:ProgressToken)), Nothing} = nothing
    "The text document."
    textDocument::TextDocumentIdentifier
    "The additional identifier  provided during registration."
    identifier::Union{String, Nothing} = nothing
    "The result id of a previous response if provided."
    previousResultId::Union{String, Nothing} = nothing
end
StructTypes.omitempties(::Type{DocumentDiagnosticParams}) =
    (:workDoneToken, :partialResultToken, :identifier, :previousResultId)

"""
The text document diagnostic request is sent from the client to the server to ask the server
to compute the diagnostics for a given document.
As with other pull requests the server is asked to compute the diagnostics for the currently synced version of the document.
"""
@kwdef struct DocumentDiagnosticRequest
    jsonrpc::String = "2.0"
    "The request id."
    id::Int
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
const DocumentDiagnosticReport = Union{RelatedFullDocumentDiagnosticReport, RelatedUnchangedDocumentDiagnosticReport}

@kwdef struct DocumentDiagnosticResponse
    jsonrpc::String = "2.0"
    "The request id."
    id::Union{Int, Nothing}
    "The error object in case a request fails."
    error::Union{ResponseError, Nothing} = nothing
    result::DocumentDiagnosticReport
end
StructTypes.omitempties(::Type{DocumentDiagnosticResponse}) = (:error,)

# message dispatcher definition
const method_dispatcher = Dict{String,DataType}(
    "textDocument/diagnostic" => DocumentDiagnosticRequest,
    "exit" => ExitNotification,
    "textDocument/didClose" => DidCloseTextDocumentNotification,
    "initialized" => InitializedNotification,
    "shutdown" => ShutdownRequest,
    "initialize" => InitializeRequest,
    "textDocument/didSave" => DidSaveTextDocumentNotification,
    "textDocument/didOpen" => DidOpenTextDocumentNotification,
    "workspace/diagnostic" => WorkspaceDiagnosticRequest,
    "textDocument/didChange" => DidChangeTextDocumentNotification)

export
    method_dispatcher,
    ClientCapabilities,
    CodeDescription,
    Diagnostic,
    DiagnosticOptions,
    DiagnosticRegistrationOptions,
    DiagnosticRelatedInformation,
    DiagnosticSeverity,
    DiagnosticTag,
    DidChangeTextDocumentNotification,
    DidChangeTextDocumentParams,
    DidCloseTextDocumentNotification,
    DidCloseTextDocumentParams,
    DidOpenTextDocumentNotification,
    DidOpenTextDocumentParams,
    DidSaveTextDocumentNotification,
    DidSaveTextDocumentParams,
    DocumentDiagnosticParams,
    DocumentDiagnosticReport,
    DocumentDiagnosticReportKind,
    DocumentDiagnosticRequest,
    DocumentDiagnosticResponse,
    DocumentFilter,
    DocumentSelector,
    DocumentUri,
    ErrorCodes,
    ExitNotification,
    FileOperationFilter,
    FileOperationPattern,
    FileOperationPatternKind,
    FileOperationPatternOptions,
    FileOperationRegistrationOptions,
    FullDocumentDiagnosticReport,
    InitializeError,
    InitializeErrorCodes,
    InitializeParams,
    InitializeRequest,
    InitializeResponse,
    InitializeResponseError,
    InitializeResult,
    InitializedNotification,
    LSPAny,
    LSPArray,
    LSPObject,
    Location,
    Message,
    NotificationMessage,
    OptionalVersionedTextDocumentIdentifier,
    PartialResultParams,
    Position,
    PositionEncodingKind,
    PreviousResultId,
    ProgressToken,
    Range,
    RelatedFullDocumentDiagnosticReport,
    RelatedUnchangedDocumentDiagnosticReport,
    RequestMessage,
    ResponseError,
    ResponseMessage,
    SaveOptions,
    ServerCapabilities,
    ShutdownRequest,
    StaticRegistrationOptions,
    TextDocumentChangeRegistrationOptions,
    TextDocumentContentChangeEvent,
    TextDocumentIdentifier,
    TextDocumentItem,
    TextDocumentRegistrationOptions,
    TextDocumentSyncKind,
    TextDocumentSyncOptions,
    TraceValue,
    URI,
    UnchangedDocumentDiagnosticReport,
    VersionedTextDocumentIdentifier,
    WorkDoneProgressOptions,
    WorkDoneProgressParams,
    WorkspaceDiagnosticParams,
    WorkspaceDiagnosticReport,
    WorkspaceDiagnosticRequest,
    WorkspaceDocumentDiagnosticReport,
    WorkspaceFolder,
    WorkspaceFoldersServerCapabilities,
    WorkspaceFullDocumentDiagnosticReport,
    WorkspaceUnchangedDocumentDiagnosticReport,
    array,
    decimal,
    integer,
    uinteger
