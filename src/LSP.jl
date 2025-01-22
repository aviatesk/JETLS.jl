@doc "Defines an integer number in the range of -2^31 to 2^31 - 1." integer

@doc "Defines an unsigned integer number in the range of 0 to 2^31 - 1." uinteger

@doc "Defines a decimal number. Since decimal numbers are very\nrare in the language server specification we denote the\nexact range with every decimal using the mathematics\ninterval notation (e.g. [0, 1] denotes all decimals d with\n0 <= d <= 1." decimal

@doc "The LSP any type\n\n# Tags\n\n- since – 3.17.0" LSPAny

@doc "LSP object definition.\n\n# Tags\n\n- since – 3.17.0" LSPObject

@doc "LSP arrays.\n\n# Tags\n\n- since – 3.17.0" LSPArray

lsptypeof(::Val{:array}) = begin
        Vector{Any}
    end
@kwdef struct Message
        jsonrpc::Core.typeof("2.0") = "2.0"
    end
@doc "A general message as defined by JSON-RPC. The language server protocol always uses “2.0” as the jsonrpc version." Message

@kwdef struct RequestMessage
        jsonrpc::Core.typeof("2.0") = "2.0"
        "The request id."
        id::Int
        "The method to be invoked."
        method::String
        "The method's params."
        params::Union{Any, Nothing} = nothing
    end
StructTypes.omitempties(::Type{RequestMessage}) = begin
        (:params,)
    end
@doc "A request message to describe a request between the client and the server. Every processed request must send a response back to the sender of the request." RequestMessage

@kwdef struct ResponseError
        "A number indicating the error type that occurred."
        code::Int
        "A string providing a short description of the error."
        message::String
        "A primitive or structured value that contains additional\ninformation about the error. Can be omitted."
        data::Union{Any, Nothing} = nothing
    end
StructTypes.omitempties(::Type{ResponseError}) = begin
        (:data,)
    end

@kwdef struct ResponseMessage
        jsonrpc::Core.typeof("2.0") = "2.0"
        "The request id."
        id::Union{Int, Core.typeof(nothing)}
        "The result of a request. This member is REQUIRED on success.\nThis member MUST NOT exist if there was an error invoking the method."
        result::Union{Any, Nothing} = nothing
        "The error object in case a request fails."
        error::Union{ResponseError, Nothing} = nothing
    end
StructTypes.omitempties(::Type{ResponseMessage}) = begin
        (:result, :error)
    end
@doc "A Response Message sent as a result of a request. If a request doesn’t provide a result value the receiver of a request still needs to return a response message to conform to the JSON-RPC specification. The result property of the ResponseMessage should be set to null in this case to signal a successful request." ResponseMessage

module ErrorCodes
const ParseError = -32700
const InvalidRequest = -32600
const MethodNotFound = -32601
const InvalidParams = -32602
const InternalError = -32603
const jsonrpcReservedErrorRangeStart = -32099
@doc "This is the start range of JSON-RPC reserved error codes.\nIt doesn't denote a real error code. No LSP error codes should\nbe defined between the start and end range. For backwards\ncompatibility the `ServerNotInitialized` and the `UnknownErrorCode`\nare left in the range.\n\n# Tags\n\n- since – 3.16.0" jsonrpcReservedErrorRangeStart
const serverErrorStart = -32099
@doc "\n\n# Tags\n\n- deprecated – use jsonrpcReservedErrorRangeStart" serverErrorStart
const ServerNotInitialized = -32002
@doc "Error code indicating that a server received a notification or\nrequest before the server has received the `initialize` request." ServerNotInitialized
const UnknownErrorCode = -32001
const jsonrpcReservedErrorRangeEnd = -32000
@doc "This is the end range of JSON-RPC reserved error codes.\nIt doesn't denote a real error code.\n\n# Tags\n\n- since – 3.16.0" jsonrpcReservedErrorRangeEnd
const serverErrorEnd = -32000
@doc "\n\n# Tags\n\n- deprecated – use jsonrpcReservedErrorRangeEnd" serverErrorEnd
const lspReservedErrorRangeStart = -32899
@doc "This is the start range of LSP reserved error codes.\nIt doesn't denote a real error code.\n\n# Tags\n\n- since – 3.16.0" lspReservedErrorRangeStart
const RequestFailed = -32803
@doc "A request failed but it was syntactically correct, e.g the\nmethod name was known and the parameters were valid. The error\nmessage should contain human readable information about why\nthe request failed.\n\n# Tags\n\n- since – 3.17.0" RequestFailed
const ServerCancelled = -32802
@doc "The server cancelled the request. This error code should\nonly be used for requests that explicitly support being\nserver cancellable.\n\n# Tags\n\n- since – 3.17.0" ServerCancelled
const ContentModified = -32801
@doc "The server detected that the content of a document got\nmodified outside normal conditions. A server should\nNOT send this error code if it detects a content change\nin it unprocessed messages. The result even computed\non an older state might still be useful for the client.\n\nIf a client decides that a result is not of any use anymore\nthe client should cancel the request." ContentModified
const RequestCancelled = -32800
@doc "The client has canceled a request and a server has detected\nthe cancel." RequestCancelled
const lspReservedErrorRangeEnd = -32800
@doc "This is the end range of LSP reserved error codes.\nIt doesn't denote a real error code.\n\n# Tags\n\n- since – 3.16.0" lspReservedErrorRangeEnd
end

@kwdef struct NotificationMessage
        jsonrpc::Core.typeof("2.0") = "2.0"
        "The method to be invoked."
        method::String
        "The notification's params."
        params::Union{Any, Nothing} = nothing
    end
StructTypes.omitempties(::Type{NotificationMessage}) = begin
        (:params,)
    end
@doc "A notification message. A processed notification message must not send a response back. They work like events." NotificationMessage

lsptypeof(::Val{:DocumentUri}) = begin
        String
    end
lsptypeof(::Val{:URI}) = begin
        String
    end
@kwdef struct Position
        "Line position in a document (zero-based)."
        line::UInt
        "Character offset on a line in a document (zero-based). The meaning of this\noffset is determined by the negotiated `PositionEncodingKind`.\n\nIf the character value is greater than the line length it defaults back\nto the line length."
        character::UInt
    end
@doc "Position in a text document expressed as zero-based line and zero-based character offset.\nA position is between two characters like an ‘insert’ cursor in an editor.\nSpecial values like for example -1 to denote the end of a line are not supported." Position

@kwdef struct WorkspaceFolder
        "The associated URI for this workspace folder."
        uri::lsptypeof(Val(:URI))
        "The name of the workspace folder. Used to refer to this\nworkspace folder in the user interface."
        name::String
    end

lsptypeof(::Val{:ProgressToken}) = begin
        Union{Int, String}
    end
@doc "The base protocol offers also support to report progress in a generic fashion. This mechanism can be used to report any kind of progress including work done progress (usually used to report progress in the user interface using a progress bar) and partial result progress to support streaming of results.\n\nA progress notification has the following properties:\nNotification:\n- method: ‘\$/progress’\n- params: ProgressParams defined as follows:" ProgressToken

@kwdef struct WorkDoneProgressParams
        "An optional token that a server can use to report work done progress."
        workDoneToken::Union{lsptypeof(Val(:ProgressToken)), Nothing} = nothing
    end
StructTypes.omitempties(::Type{WorkDoneProgressParams}) = begin
        (:workDoneToken,)
    end

@kwdef struct PartialResultParams
        "An optional token that a server can use to report partial results (e.g.\nstreaming) to the client."
        partialResultToken::Union{lsptypeof(Val(:ProgressToken)), Nothing} = nothing
    end
StructTypes.omitempties(::Type{PartialResultParams}) = begin
        (:partialResultToken,)
    end

lsptypeof(::Val{:TraceValue}) = begin
        Union{Core.typeof("off"), Core.typeof("messages"), Core.typeof("verbose")}
    end
@doc "A TraceValue represents the level of verbosity with which the server systematically reports its execution trace using \$/logTrace notifications. The initial trace value is set by the client at initialization and can be modified later using the \$/setTrace notification." TraceValue

@kwdef struct var"##AnonymousType#231"
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
StructTypes.omitempties(::Type{var"##AnonymousType#231"}) = begin
        (:dynamicRegistration, :didCreate, :willCreate, :didRename, :willRename, :didDelete, :willDelete)
    end
Base.convert(::Type{var"##AnonymousType#231"}, nt::NamedTuple) = begin
        var"##AnonymousType#231"(; nt...)
    end
@kwdef struct var"##AnonymousType#230"
        "The client supports applying batch edits\nto the workspace by supporting the request\n'workspace/applyEdit'"
        applyEdit::Union{Bool, Nothing} = nothing
        "The client has support for workspace folders.\n\n# Tags\n\n- since – 3.6.0"
        workspaceFolders::Union{Bool, Nothing} = nothing
        "The client has support for file requests/notifications.\n\n# Tags\n\n- since – 3.16.0"
        fileOperations::Union{var"##AnonymousType#231", Nothing} = nothing
    end
StructTypes.omitempties(::Type{var"##AnonymousType#230"}) = begin
        (:applyEdit, :workspaceFolders, :fileOperations)
    end
Base.convert(::Type{var"##AnonymousType#230"}, nt::NamedTuple) = begin
        var"##AnonymousType#230"(; nt...)
    end
@kwdef struct ClientCapabilities
        "Workspace specific client capabilities."
        workspace::Union{var"##AnonymousType#230", Nothing} = nothing
        "Experimental client capabilities."
        experimental::Union{Any, Nothing} = nothing
    end
StructTypes.omitempties(::Type{ClientCapabilities}) = begin
        (:workspace, :experimental)
    end

module FileOperationPatternKind
const file = "file"
@doc "The pattern matches a file only." file
const folder = "folder"
@doc "The pattern matches a folder only." folder
end
@doc "A pattern kind describing if a glob pattern matches a file a folder or\nboth.\n\n# Tags\n\n- since – 3.16.0" FileOperationPatternKind

lsptypeof(::Val{:FileOperationPatternKind}) = begin
        Union{Core.typeof("file"), Core.typeof("folder")}
    end
@kwdef struct FileOperationPatternOptions
        "The pattern should be matched ignoring casing."
        ignoreCase::Union{Bool, Nothing} = nothing
    end
StructTypes.omitempties(::Type{FileOperationPatternOptions}) = begin
        (:ignoreCase,)
    end
@doc "Matching options for the file operation pattern.\n\n# Tags\n\n- since – 3.16.0" FileOperationPatternOptions

@kwdef struct FileOperationPattern
        "The glob pattern to match. Glob patterns can have the following syntax:\n- `*` to match one or more characters in a path segment\n- `?` to match on one character in a path segment\n- `**` to match any number of path segments, including none\n- `{}` to group sub patterns into an OR expression. (e.g. `**\u200b/*.{ts,js}`\n  matches all TypeScript and JavaScript files)\n- `[]` to declare a range of characters to match in a path segment\n  (e.g., `example.[0-9]` to match on `example.0`, `example.1`, …)\n- `[!...]` to negate a range of characters to match in a path segment\n  (e.g., `example.[!0-9]` to match on `example.a`, `example.b`, but\n  not `example.0`)"
        glob::String
        "Whether to match files or folders with this pattern.\n\nMatches both if undefined."
        matches::Union{lsptypeof(Val(:FileOperationPatternKind)), Nothing} = nothing
        "Additional options used during matching."
        options::Union{FileOperationPatternOptions, Nothing} = nothing
    end
StructTypes.omitempties(::Type{FileOperationPattern}) = begin
        (:matches, :options)
    end
@doc "A pattern to describe in which file operation requests or notifications\nthe server is interested in.\n\n# Tags\n\n- since – 3.16.0" FileOperationPattern

@kwdef struct FileOperationFilter
        "A Uri like `file` or `untitled`."
        scheme::Union{String, Nothing} = nothing
        "The actual file operation pattern."
        pattern::FileOperationPattern
    end
StructTypes.omitempties(::Type{FileOperationFilter}) = begin
        (:scheme,)
    end
@doc "A filter to describe in which file operation requests or notifications\nthe server is interested in.\n\n# Tags\n\n- since – 3.16.0" FileOperationFilter

@kwdef struct FileOperationRegistrationOptions
        "The actual filters."
        filters::Vector{FileOperationFilter}
    end
@doc "The options to register for file operations.\n\n# Tags\n\n- since – 3.16.0" FileOperationRegistrationOptions

@kwdef struct var"##AnonymousType#232"
        "The name of the client as defined by the client."
        name::String
        "The client's version as defined by the client."
        version::Union{String, Nothing} = nothing
    end
StructTypes.omitempties(::Type{var"##AnonymousType#232"}) = begin
        (:version,)
    end
Base.convert(::Type{var"##AnonymousType#232"}, nt::NamedTuple) = begin
        var"##AnonymousType#232"(; nt...)
    end
@kwdef struct InitializeParams
        "An optional token that a server can use to report work done progress."
        workDoneToken::Union{lsptypeof(Val(:ProgressToken)), Nothing} = nothing
        "The process Id of the parent process that started the server. Is null if\nthe process has not been started by another process. If the parent\nprocess is not alive then the server should exit (see exit notification)\nits process."
        processId::Union{Int, Core.typeof(nothing)}
        "Information about the client\n\n# Tags\n\n- since – 3.15.0"
        clientInfo::Union{var"##AnonymousType#232", Nothing} = nothing
        "The locale the client is currently showing the user interface\nin. This must not necessarily be the locale of the operating\nsystem.\n\nUses IETF language tags as the value's syntax\n(See https://en.wikipedia.org/wiki/IETF_language_tag)\n\n# Tags\n\n- since – 3.16.0"
        locale::Union{String, Nothing} = nothing
        "The rootPath of the workspace. Is null\nif no folder is open.\n\n# Tags\n\n- deprecated – in favour of `rootUri`."
        rootPath::Union{Union{String, Core.typeof(nothing)}, Nothing} = nothing
        "The rootUri of the workspace. Is null if no\nfolder is open. If both `rootPath` and `rootUri` are set\n`rootUri` wins.\n\n# Tags\n\n- deprecated – in favour of `workspaceFolders`"
        rootUri::Union{lsptypeof(Val(:DocumentUri)), Core.typeof(nothing)}
        "User provided initialization options."
        initializationOptions::Union{Any, Nothing} = nothing
        "The capabilities provided by the client (editor or tool)"
        capabilities::ClientCapabilities
        "The initial trace setting. If omitted trace is disabled ('off')."
        trace::Union{lsptypeof(Val(:TraceValue)), Nothing} = nothing
        "The workspace folders configured in the client when the server starts.\nThis property is only available if the client supports workspace folders.\nIt can be `null` if the client supports workspace folders but none are\nconfigured.\n\n# Tags\n\n- since – 3.6.0"
        workspaceFolders::Union{Union{Vector{WorkspaceFolder}, Core.typeof(nothing)}, Nothing} = nothing
    end
StructTypes.omitempties(::Type{InitializeParams}) = begin
        (:workDoneToken, :clientInfo, :locale, :rootPath, :initializationOptions, :trace, :workspaceFolders)
    end

@kwdef struct InitializeRequest
        jsonrpc::Core.typeof("2.0") = "2.0"
        "The request id."
        id::Int
        method::Core.typeof("initialize")
        params::InitializeParams
    end
@doc "The initialize request is sent as the first request from the client to the server. If the server receives a request or notification before the initialize request it should act as follows:\n- For a request the response should be an error with code: -32002. The message can be picked by the server.\n- Notifications should be dropped, except for the exit notification. This will allow the exit of a server without an initialize request.\nUntil the server has responded to the initialize request with an InitializeResult, the client must not send any additional requests or notifications to the server. In addition the server is not allowed to send any requests or notifications to the client until it has responded with an InitializeResult, with the exception that during the initialize request the server is allowed to send the notifications window/showMessage, window/logMessage and telemetry/event as well as the window/showMessageRequest request to the client. In case the client sets up a progress token in the initialize params (e.g. property workDoneToken) the server is also allowed to use that token (and only that token) using the \$/progress notification sent from the server to the client.\nThe initialize request may only be sent once." InitializeRequest

@kwdef struct InitializedNotification
        jsonrpc::Core.typeof("2.0") = "2.0"
        "The notification's params."
        params::Union{Any, Nothing} = nothing
        method::Core.typeof("initialized")
    end
StructTypes.omitempties(::Type{InitializedNotification}) = begin
        (:params,)
    end
@doc "The initialized notification is sent from the client to the server after the client received the result of the initialize request but before the client is sending any other request or notification to the server. The server can use the initialized notification, for example, to dynamically register capabilities. The initialized notification may only be sent once." InitializedNotification

@kwdef struct ShutdownRequest
        jsonrpc::Core.typeof("2.0") = "2.0"
        "The request id."
        id::Int
        "The method's params."
        params::Union{Any, Nothing} = nothing
        method::Core.typeof("shutdown")
    end
StructTypes.omitempties(::Type{ShutdownRequest}) = begin
        (:params,)
    end

@kwdef struct ExitNotification
        jsonrpc::Core.typeof("2.0") = "2.0"
        "The notification's params."
        params::Union{Any, Nothing} = nothing
        method::Core.typeof("exit")
    end
StructTypes.omitempties(::Type{ExitNotification}) = begin
        (:params,)
    end

lsptypeof(::Val{:PositionEncodingKind}) = begin
        String
    end
@doc "A type indicating how positions are encoded,\nspecifically what column offsets mean.\n\n# Tags\n\n- since – 3.17.0" PositionEncodingKind

module PositionEncodingKind
const UTF8 = "utf-8"
@doc "Character offsets count UTF-8 code units (e.g bytes)." UTF8
const UTF16 = "utf-16"
@doc "Character offsets count UTF-16 code units.\n\nThis is the default and must always be supported\nby servers" UTF16
const UTF32 = "utf-32"
@doc "Character offsets count UTF-32 code units.\n\nImplementation note: these are the same as Unicode code points,\nso this `PositionEncodingKind` may also be used for an\nencoding-agnostic representation of character offsets." UTF32
end
@doc "A set of predefined position encoding kinds.\n\n# Tags\n\n- since – 3.17.0" PositionEncodingKind

@kwdef struct Range
        "The range's start position."
        start::Position
        "The range's end position."
        var"end"::Position
    end
@doc "A range in a text document expressed as (zero-based) start and end positions. A range is comparable to a selection in an editor. Therefore, the end position is exclusive. If you want to specify a range that contains a line including the line ending character(s) then use an end position denoting the start of the next line. For example:\n```json\n{\n\t   start: { line: 5, character: 23 },\n\t\t end : { line: 6, character: 0 }\n}\n```" Range

@kwdef struct TextDocumentItem
        "The text document's URI."
        uri::lsptypeof(Val(:DocumentUri))
        "The text document's language identifier."
        languageId::String
        "The version number of this document (it will increase after each\nchange, including undo/redo)."
        version::Int
        "The content of the opened text document."
        text::String
    end
@doc "An item to transfer a text document from the client to the server." TextDocumentItem

@kwdef struct TextDocumentIdentifier
        "The text document's URI."
        uri::lsptypeof(Val(:DocumentUri))
    end
@doc "Text documents are identified using a URI. On the protocol level, URIs are passed as strings. The corresponding JSON structure looks like this:" TextDocumentIdentifier

@kwdef struct VersionedTextDocumentIdentifier
        "The text document's URI."
        uri::lsptypeof(Val(:DocumentUri))
        "The version number of this document.\n\nThe version number of a document will increase after each change,\nincluding undo/redo. The number doesn't need to be consecutive."
        version::Int
    end
@doc "An identifier to denote a specific version of a text document. This information usually flows from the client to the server." VersionedTextDocumentIdentifier

@kwdef struct OptionalVersionedTextDocumentIdentifier
        "The text document's URI."
        uri::lsptypeof(Val(:DocumentUri))
        "The version number of this document. If an optional versioned text document\nidentifier is sent from the server to the client and the file is not\nopen in the editor (the server has not received an open notification\nbefore) the server can send `null` to indicate that the version is\nknown and the content on disk is the master (as specified with document\ncontent ownership).\n\nThe version number of a document will increase after each change,\nincluding undo/redo. The number doesn't need to be consecutive."
        version::Union{Int, Core.typeof(nothing)}
    end
@doc "An identifier which optionally denotes a specific version of a text document. This information usually flows from the server to the client." OptionalVersionedTextDocumentIdentifier

module TextDocumentSyncKind
const None = 0
@doc "Documents should not be synced at all." None
const Full = 1
@doc "Documents are synced by always sending the full content\nof the document." Full
const Incremental = 2
@doc "Documents are synced by sending the full content on open.\nAfter that only incremental updates to the document are\nsent." Incremental
end
@doc "Defines how the host (editor) should sync document changes to the language\nserver." TextDocumentSyncKind

lsptypeof(::Val{:TextDocumentSyncKind}) = begin
        Union{Core.typeof(0), Core.typeof(1), Core.typeof(2)}
    end
@kwdef struct DocumentFilter
        "A language id, like `typescript`."
        language::Union{String, Nothing} = nothing
        "A Uri scheme, like `file` or `untitled`."
        scheme::Union{String, Nothing} = nothing
        "A glob pattern, like `*.{ts,js}`.\n\nGlob patterns can have the following syntax:\n- `*` to match one or more characters in a path segment\n- `?` to match on one character in a path segment\n- `**` to match any number of path segments, including none\n- `{}` to group sub patterns into an OR expression. (e.g. `**\u200b/*.{ts,js}`\n  matches all TypeScript and JavaScript files)\n- `[]` to declare a range of characters to match in a path segment\n  (e.g., `example.[0-9]` to match on `example.0`, `example.1`, …)\n- `[!...]` to negate a range of characters to match in a path segment\n  (e.g., `example.[!0-9]` to match on `example.a`, `example.b`, but\n  not `example.0`)"
        pattern::Union{String, Nothing} = nothing
    end
StructTypes.omitempties(::Type{DocumentFilter}) = begin
        (:language, :scheme, :pattern)
    end
@doc "A document filter denotes a document through properties like language, scheme or pattern. An example is a filter that applies to TypeScript files on disk. Another example is a filter that applies to JSON files with name package.json:\n```json\n{ language: 'typescript', scheme: 'file' }\n{ language: 'json', pattern: '**\\/package.json' }\n```\n\nPlease note that for a document filter to be valid at least one of the properties for language, scheme, or pattern must be set. To keep the type definition simple all properties are marked as optional." DocumentFilter

lsptypeof(::Val{:DocumentSelector}) = begin
        Vector{DocumentFilter}
    end
@doc "A document selector is the combination of one or more document filters." DocumentSelector

@kwdef struct TextDocumentRegistrationOptions
        "A document selector to identify the scope of the registration. If set to\nnull the document selector provided on the client side will be used."
        documentSelector::Union{lsptypeof(Val(:DocumentSelector)), Core.typeof(nothing)}
    end
@doc "General text document registration options." TextDocumentRegistrationOptions

@kwdef struct DidOpenTextDocumentParams
        "The document that was opened."
        textDocument::TextDocumentItem
    end

@kwdef struct DidOpenTextDocumentNotification
        jsonrpc::Core.typeof("2.0") = "2.0"
        method::Core.typeof("textDocument/didOpen")
        params::DidOpenTextDocumentParams
    end
@doc "The document open notification is sent from the client to the server to signal newly opened text documents. The document’s content is now managed by the client and the server must not try to read the document’s content using the document’s Uri. Open in this sense means it is managed by the client. It doesn’t necessarily mean that its content is presented in an editor. An open notification must not be sent more than once without a corresponding close notification send before. This means open and close notification must be balanced and the max open count for a particular textDocument is one. Note that a server’s ability to fulfill requests is independent of whether a text document is open or closed.\n\nThe DidOpenTextDocumentParams contain the language id the document is associated with. If the language id of a document changes, the client needs to send a textDocument/didClose to the server followed by a textDocument/didOpen with the new language id if the server handles the new language id as well." DidOpenTextDocumentNotification

@kwdef struct TextDocumentChangeRegistrationOptions
        "A document selector to identify the scope of the registration. If set to\nnull the document selector provided on the client side will be used."
        documentSelector::Union{lsptypeof(Val(:DocumentSelector)), Core.typeof(nothing)}
        "How documents are synced to the server. See TextDocumentSyncKind.Full\nand TextDocumentSyncKind.Incremental."
        syncKind::lsptypeof(Val(:TextDocumentSyncKind))
    end
@doc "Describe options to be used when registering for text document change events." TextDocumentChangeRegistrationOptions

@kwdef struct TextDocumentContentChangeEvent
        "The range of the document that changed."
        range::Union{Range, Nothing} = nothing
        "The optional length of the range that got replaced.\n\n# Tags\n\n- deprecated – use range instead."
        rangeLength::Union{UInt, Nothing} = nothing
        "The new text for the provided range."
        text::String
    end
StructTypes.omitempties(::Type{TextDocumentContentChangeEvent}) = begin
        (:range, :rangeLength)
    end
@doc "An event describing a change to a text document. If only a text is provided\nit is considered to be the full content of the document." TextDocumentContentChangeEvent

@kwdef struct DidChangeTextDocumentParams
        "The document that did change. The version number points\nto the version after all provided content changes have\nbeen applied."
        textDocument::VersionedTextDocumentIdentifier
        "The actual content changes. The content changes describe single state\nchanges to the document. So if there are two content changes c1 (at\narray index 0) and c2 (at array index 1) for a document in state S then\nc1 moves the document from S to S' and c2 from S' to S''. So c1 is\ncomputed on the state S and c2 is computed on the state S'.\n\nTo mirror the content of a document using change events use the following\napproach:\n- start with the same initial content\n- apply the 'textDocument/didChange' notifications in the order you\n  receive them.\n- apply the `TextDocumentContentChangeEvent`s in a single notification\n  in the order you receive them."
        contentChanges::Vector{TextDocumentContentChangeEvent}
    end

@kwdef struct DidChangeTextDocumentNotification
        jsonrpc::Core.typeof("2.0") = "2.0"
        method::Core.typeof("textDocument/didChange")
        params::DidChangeTextDocumentParams
    end
@doc "The document change notification is sent from the client to the server to signal changes to a text document. Before a client can change a text document it must claim ownership of its content using the textDocument/didOpen notification. In 2.0 the shape of the params has changed to include proper version numbers." DidChangeTextDocumentNotification

@kwdef struct DidCloseTextDocumentParams
        "The document that was closed."
        textDocument::TextDocumentIdentifier
    end

@kwdef struct DidCloseTextDocumentNotification
        jsonrpc::Core.typeof("2.0") = "2.0"
        method::Core.typeof("textDocument/didClose")
        params::DidCloseTextDocumentParams
    end
@doc "The document close notification is sent from the client to the server when the document got closed in the client. The document’s master now exists where the document’s Uri points to (e.g. if the document’s Uri is a file Uri the master now exists on disk). As with the open notification the close notification is about managing the document’s content. Receiving a close notification doesn’t mean that the document was open in an editor before. A close notification requires a previous open notification to be sent. Note that a server’s ability to fulfill requests is independent of whether a text document is open or closed." DidCloseTextDocumentNotification

@kwdef struct SaveOptions
        "The client is supposed to include the content on save."
        includeText::Union{Bool, Nothing} = nothing
    end
StructTypes.omitempties(::Type{SaveOptions}) = begin
        (:includeText,)
    end

@kwdef struct DidSaveTextDocumentParams
        "The document that was saved."
        textDocument::TextDocumentIdentifier
        "Optional the content when saved. Depends on the includeText value\nwhen the save notification was requested."
        text::Union{String, Nothing} = nothing
    end
StructTypes.omitempties(::Type{DidSaveTextDocumentParams}) = begin
        (:text,)
    end

@kwdef struct DidSaveTextDocumentNotification
        jsonrpc::Core.typeof("2.0") = "2.0"
        method::Core.typeof("textDocument/didSave")
        params::DidSaveTextDocumentParams
    end

@kwdef struct TextDocumentSyncOptions
        "Open and close notifications are sent to the server. If omitted open\nclose notification should not be sent."
        openClose::Union{Bool, Nothing} = nothing
        "Change notifications are sent to the server. See\nTextDocumentSyncKind.None, TextDocumentSyncKind.Full and\nTextDocumentSyncKind.Incremental. If omitted it defaults to\nTextDocumentSyncKind.None."
        change::Union{lsptypeof(Val(:TextDocumentSyncKind)), Nothing} = nothing
        "If present will save notifications are sent to the server. If omitted\nthe notification should not be sent."
        willSave::Union{Bool, Nothing} = nothing
        "If present will save wait until requests are sent to the server. If\nomitted the request should not be sent."
        willSaveWaitUntil::Union{Bool, Nothing} = nothing
        "If present save notifications are sent to the server. If omitted the\nnotification should not be sent."
        save::Union{Union{Bool, SaveOptions}, Nothing} = nothing
    end
StructTypes.omitempties(::Type{TextDocumentSyncOptions}) = begin
        (:openClose, :change, :willSave, :willSaveWaitUntil, :save)
    end

@kwdef struct WorkDoneProgressOptions
        workDoneProgress::Union{Bool, Nothing} = nothing
    end
StructTypes.omitempties(::Type{WorkDoneProgressOptions}) = begin
        (:workDoneProgress,)
    end

@kwdef struct DiagnosticOptions
        workDoneProgress::Union{Bool, Nothing} = nothing
        "An optional identifier under which the diagnostics are\nmanaged by the client."
        identifier::Union{String, Nothing} = nothing
        "Whether the language has inter file dependencies meaning that\nediting code in one file can result in a different diagnostic\nset in another file. Inter file dependencies are common for\nmost programming languages and typically uncommon for linters."
        interFileDependencies::Bool
        "The server provides support for workspace diagnostics as well."
        workspaceDiagnostics::Bool
    end
StructTypes.omitempties(::Type{DiagnosticOptions}) = begin
        (:workDoneProgress, :identifier)
    end
@doc "Diagnostic options.\n\n# Tags\n\n- since – 3.17.0" DiagnosticOptions

@kwdef struct StaticRegistrationOptions
        "The id used to register the request. The id can be used to deregister\nthe request again. See also Registration#id."
        id::Union{String, Nothing} = nothing
    end
StructTypes.omitempties(::Type{StaticRegistrationOptions}) = begin
        (:id,)
    end
@doc "Static registration options to be returned in the initialize request." StaticRegistrationOptions

@kwdef struct WorkspaceFoldersServerCapabilities
        "The server has support for workspace folders"
        supported::Union{Bool, Nothing} = nothing
        "Whether the server wants to receive workspace folder\nchange notifications.\n\nIf a string is provided, the string is treated as an ID\nunder which the notification is registered on the client\nside. The ID can be used to unregister for these events\nusing the `client/unregisterCapability` request."
        changeNotifications::Union{Union{String, Bool}, Nothing} = nothing
    end
StructTypes.omitempties(::Type{WorkspaceFoldersServerCapabilities}) = begin
        (:supported, :changeNotifications)
    end
@doc "Since version 3.6.0\n\nMany tools support more than one root folder per workspace. Examples for this are VS Code’s multi-root support, Atom’s project folder support or Sublime’s project support. If a client workspace consists of multiple roots then a server typically needs to know about this. The protocol up to now assumes one root folder which is announced to the server by the rootUri property of the InitializeParams. If the client supports workspace folders and announces them via the corresponding workspaceFolders client capability, the InitializeParams contain an additional property workspaceFolders with the configured workspace folders when the server starts.\n\nThe workspace/workspaceFolders request is sent from the server to the client to fetch the current open list of workspace folders. Returns null in the response if only a single file is open in the tool. Returns an empty array if a workspace is open but no folders are configured." WorkspaceFoldersServerCapabilities

@kwdef struct DiagnosticRegistrationOptions
        "A document selector to identify the scope of the registration. If set to\nnull the document selector provided on the client side will be used."
        documentSelector::Union{lsptypeof(Val(:DocumentSelector)), Core.typeof(nothing)}
        workDoneProgress::Union{Bool, Nothing} = nothing
        "An optional identifier under which the diagnostics are\nmanaged by the client."
        identifier::Union{String, Nothing} = nothing
        "Whether the language has inter file dependencies meaning that\nediting code in one file can result in a different diagnostic\nset in another file. Inter file dependencies are common for\nmost programming languages and typically uncommon for linters."
        interFileDependencies::Bool
        "The server provides support for workspace diagnostics as well."
        workspaceDiagnostics::Bool
        "The id used to register the request. The id can be used to deregister\nthe request again. See also Registration#id."
        id::Union{String, Nothing} = nothing
    end
StructTypes.omitempties(::Type{DiagnosticRegistrationOptions}) = begin
        (:workDoneProgress, :identifier, :id)
    end
@doc "Diagnostic registration options.\n\n# Tags\n\n- since – 3.17.0" DiagnosticRegistrationOptions

@kwdef struct var"##AnonymousType#234"
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
StructTypes.omitempties(::Type{var"##AnonymousType#234"}) = begin
        (:didCreate, :willCreate, :didRename, :willRename, :didDelete, :willDelete)
    end
Base.convert(::Type{var"##AnonymousType#234"}, nt::NamedTuple) = begin
        var"##AnonymousType#234"(; nt...)
    end
@kwdef struct var"##AnonymousType#233"
        "The server supports workspace folder.\n\n# Tags\n\n- since – 3.6.0"
        workspaceFolders::Union{WorkspaceFoldersServerCapabilities, Nothing} = nothing
        "The server is interested in file notifications/requests.\n\n# Tags\n\n- since – 3.16.0"
        fileOperations::Union{var"##AnonymousType#234", Nothing} = nothing
    end
StructTypes.omitempties(::Type{var"##AnonymousType#233"}) = begin
        (:workspaceFolders, :fileOperations)
    end
Base.convert(::Type{var"##AnonymousType#233"}, nt::NamedTuple) = begin
        var"##AnonymousType#233"(; nt...)
    end
@kwdef struct ServerCapabilities
        "The position encoding the server picked from the encodings offered\nby the client via the client capability `general.positionEncodings`.\n\nIf the client didn't provide any position encodings the only valid\nvalue that a server can return is 'utf-16'.\n\nIf omitted it defaults to 'utf-16'.\n\n# Tags\n\n- since – 3.17.0"
        positionEncoding::Union{lsptypeof(Val(:PositionEncodingKind)), Nothing} = nothing
        "Defines how text documents are synced. Is either a detailed structure\ndefining each notification or for backwards compatibility the\nTextDocumentSyncKind number. If omitted it defaults to\n`TextDocumentSyncKind.None`."
        textDocumentSync::Union{Union{TextDocumentSyncOptions, lsptypeof(Val(:TextDocumentSyncKind))}, Nothing} = nothing
        "The server has support for pull model diagnostics.\n\n# Tags\n\n- since – 3.17.0"
        diagnosticProvider::Union{Union{DiagnosticOptions, DiagnosticRegistrationOptions}, Nothing} = nothing
        "Workspace specific server capabilities"
        workspace::Union{var"##AnonymousType#233", Nothing} = nothing
    end
StructTypes.omitempties(::Type{ServerCapabilities}) = begin
        (:positionEncoding, :textDocumentSync, :diagnosticProvider, :workspace)
    end

@kwdef struct var"##AnonymousType#235"
        "The name of the server as defined by the server."
        name::String
        "The server's version as defined by the server."
        version::Union{String, Nothing} = nothing
    end
StructTypes.omitempties(::Type{var"##AnonymousType#235"}) = begin
        (:version,)
    end
Base.convert(::Type{var"##AnonymousType#235"}, nt::NamedTuple) = begin
        var"##AnonymousType#235"(; nt...)
    end
@kwdef struct InitializeResult
        "The capabilities the language server provides."
        capabilities::ServerCapabilities
        "Information about the server.\n\n# Tags\n\n- since – 3.15.0"
        serverInfo::Union{var"##AnonymousType#235", Nothing} = nothing
    end
StructTypes.omitempties(::Type{InitializeResult}) = begin
        (:serverInfo,)
    end

module InitializeErrorCodes
const unknownProtocolVersion = 1
@doc "If the protocol version provided by the client can't be handled by\nthe server.\n\n# Tags\n\n- deprecated – This initialize error got replaced by client capabilities.\nThere is no version handshake in version 3.0x" unknownProtocolVersion
end
@doc "Known error codes for an `InitializeErrorCodes`;" InitializeErrorCodes

lsptypeof(::Val{:InitializeErrorCodes}) = begin
        Core.typeof(1)
    end
@kwdef struct InitializeError
        "Indicates whether the client execute the following retry logic:\n(1) show the message provided by the ResponseError to the user\n(2) user selects retry or cancel\n(3) if user selected retry the initialize method is sent again."
        retry::Bool
    end

@kwdef struct InitializeResponseError
        "A string providing a short description of the error."
        message::String
        code::lsptypeof(Val(:InitializeErrorCodes))
        data::InitializeError
    end

@kwdef struct InitializeResponse
        jsonrpc::Core.typeof("2.0") = "2.0"
        "The request id."
        id::Union{Int, Core.typeof(nothing)}
        result::Union{InitializeResult, Nothing} = nothing
        error::Union{InitializeResponseError, Nothing} = nothing
    end
StructTypes.omitempties(::Type{InitializeResponse}) = begin
        (:result, :error)
    end

module DocumentDiagnosticReportKind
const Full = "full"
@doc "A diagnostic report with a full\nset of problems." Full
const Unchanged = "unchanged"
@doc "A report indicating that the last\nreturned report is still accurate." Unchanged
end
@doc "The document diagnostic report kinds.\n\n# Tags\n\n- since – 3.17.0" DocumentDiagnosticReportKind

lsptypeof(::Val{:DocumentDiagnosticReportKind}) = begin
        Union{Core.typeof("full"), Core.typeof("unchanged")}
    end
module DiagnosticSeverity
const Error = 1
@doc "Reports an error." Error
const Warning = 2
@doc "Reports a warning." Warning
const Information = 3
@doc "Reports an information." Information
const Hint = 4
@doc "Reports a hint." Hint
end

lsptypeof(::Val{:DiagnosticSeverity}) = begin
        Union{Core.typeof(1), Core.typeof(2), Core.typeof(3), Core.typeof(4)}
    end
@kwdef struct CodeDescription
        "An URI to open with more information about the diagnostic error."
        href::lsptypeof(Val(:URI))
    end
@doc "Structure to capture a description for an error code.\n\n# Tags\n\n- since – 3.16.0" CodeDescription

module DiagnosticTag
const Unnecessary = 1
@doc "Unused or unnecessary code.\n\nClients are allowed to render diagnostics with this tag faded out\ninstead of having an error squiggle." Unnecessary
const Deprecated = 2
@doc "Deprecated or obsolete code.\n\nClients are allowed to rendered diagnostics with this tag strike through." Deprecated
end
@doc "The diagnostic tags.\n\n# Tags\n\n- since – 3.15.0" DiagnosticTag

lsptypeof(::Val{:DiagnosticTag}) = begin
        Union{Core.typeof(1), Core.typeof(2)}
    end
@kwdef struct Location
        uri::lsptypeof(Val(:DocumentUri))
        range::Range
    end
@doc "Represents a location inside a resource, such as a line inside a text file." Location

@kwdef struct DiagnosticRelatedInformation
        "The location of this related diagnostic information."
        location::Location
        "The message of this related diagnostic information."
        message::String
    end
@doc "Represents a related message and source code location for a diagnostic.\nThis should be used to point to code locations that cause or are related to\na diagnostics, e.g when duplicating a symbol in a scope." DiagnosticRelatedInformation

@kwdef struct Diagnostic
        "The range at which the message applies."
        range::Range
        "The diagnostic's severity. To avoid interpretation mismatches when a\nserver is used with different clients it is highly recommended that\nservers always provide a severity value. If omitted, it’s recommended\nfor the client to interpret it as an Error severity."
        severity::Union{lsptypeof(Val(:DiagnosticSeverity)), Nothing} = nothing
        "The diagnostic's code, which might appear in the user interface."
        code::Union{Union{Int, String}, Nothing} = nothing
        "An optional property to describe the error code.\n\n# Tags\n\n- since – 3.16.0"
        codeDescription::Union{CodeDescription, Nothing} = nothing
        "A human-readable string describing the source of this\ndiagnostic, e.g. 'typescript' or 'super lint'."
        source::Union{String, Nothing} = nothing
        "The diagnostic's message."
        message::String
        "Additional metadata about the diagnostic.\n\n# Tags\n\n- since – 3.15.0"
        tags::Union{Vector{lsptypeof(Val(:DiagnosticTag))}, Nothing} = nothing
        "An array of related diagnostic information, e.g. when symbol-names within\na scope collide all definitions can be marked via this property."
        relatedInformation::Union{Vector{DiagnosticRelatedInformation}, Nothing} = nothing
        "A data entry field that is preserved between a\n`textDocument/publishDiagnostics` notification and\n`textDocument/codeAction` request.\n\n# Tags\n\n- since – 3.16.0"
        data::Union{Any, Nothing} = nothing
    end
StructTypes.omitempties(::Type{Diagnostic}) = begin
        (:severity, :code, :codeDescription, :source, :tags, :relatedInformation, :data)
    end

@kwdef struct FullDocumentDiagnosticReport
        "A full document diagnostic report."
        kind::lsptypeof(Val(:DocumentDiagnosticReportKind))
        "An optional result id. If provided it will\nbe sent on the next diagnostic request for the\nsame document."
        resultId::Union{String, Nothing} = nothing
        "The actual items."
        items::Vector{Diagnostic}
    end
StructTypes.omitempties(::Type{FullDocumentDiagnosticReport}) = begin
        (:resultId,)
    end
@doc "A diagnostic report with a full set of problems.\n\n# Tags\n\n- since – 3.17.0" FullDocumentDiagnosticReport

@kwdef struct UnchangedDocumentDiagnosticReport
        "A document diagnostic report indicating\nno changes to the last result. A server can\nonly return `unchanged` if result ids are\nprovided."
        kind::lsptypeof(Val(:DocumentDiagnosticReportKind))
        "A result id which will be sent on the next\ndiagnostic request for the same document."
        resultId::String
    end
@doc "A diagnostic report indicating that the last returned\nreport is still accurate.\n\n# Tags\n\n- since – 3.17.0" UnchangedDocumentDiagnosticReport

@kwdef struct WorkspaceFullDocumentDiagnosticReport
        "A full document diagnostic report."
        kind::lsptypeof(Val(:DocumentDiagnosticReportKind))
        "An optional result id. If provided it will\nbe sent on the next diagnostic request for the\nsame document."
        resultId::Union{String, Nothing} = nothing
        "The actual items."
        items::Vector{Diagnostic}
        "The URI for which diagnostic information is reported."
        uri::lsptypeof(Val(:DocumentUri))
        "The version number for which the diagnostics are reported.\nIf the document is not marked as open `null` can be provided."
        version::Union{Int, Core.typeof(nothing)}
    end
StructTypes.omitempties(::Type{WorkspaceFullDocumentDiagnosticReport}) = begin
        (:resultId,)
    end
@doc "A full document diagnostic report for a workspace diagnostic result.\n\n# Tags\n\n- since – 3.17.0" WorkspaceFullDocumentDiagnosticReport

@kwdef struct WorkspaceUnchangedDocumentDiagnosticReport
        "A document diagnostic report indicating\nno changes to the last result. A server can\nonly return `unchanged` if result ids are\nprovided."
        kind::lsptypeof(Val(:DocumentDiagnosticReportKind))
        "A result id which will be sent on the next\ndiagnostic request for the same document."
        resultId::String
        "The URI for which diagnostic information is reported."
        uri::lsptypeof(Val(:DocumentUri))
        "The version number for which the diagnostics are reported.\nIf the document is not marked as open `null` can be provided."
        version::Union{Int, Core.typeof(nothing)}
    end
@doc "An unchanged document diagnostic report for a workspace diagnostic result.\n\n# Tags\n\n- since – 3.17.0" WorkspaceUnchangedDocumentDiagnosticReport

lsptypeof(::Val{:WorkspaceDocumentDiagnosticReport}) = begin
        Union{WorkspaceFullDocumentDiagnosticReport, WorkspaceUnchangedDocumentDiagnosticReport}
    end
@doc "A workspace diagnostic document report.\n\n# Tags\n\n- since – 3.17.0" WorkspaceDocumentDiagnosticReport

@kwdef struct WorkspaceDiagnosticReport
        items::Vector{lsptypeof(Val(:WorkspaceDocumentDiagnosticReport))}
    end
@doc "A workspace diagnostic report.\n\n# Tags\n\n- since – 3.17.0" WorkspaceDiagnosticReport

@kwdef struct PreviousResultId
        "The URI for which the client knows a\nresult id."
        uri::lsptypeof(Val(:DocumentUri))
        "The value of the previous result id."
        value::String
    end
@doc "A previous result id in a workspace pull request.\n\n# Tags\n\n- since – 3.17.0" PreviousResultId

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
StructTypes.omitempties(::Type{WorkspaceDiagnosticParams}) = begin
        (:workDoneToken, :partialResultToken, :identifier)
    end
@doc "Parameters of the workspace diagnostic request.\n\n# Tags\n\n- since – 3.17.0" WorkspaceDiagnosticParams

@kwdef struct WorkspaceDiagnosticRequest
        jsonrpc::Core.typeof("2.0") = "2.0"
        "The request id."
        id::Int
        method::Core.typeof("workspace/diagnostic")
        params::WorkspaceDiagnosticParams
    end

# message dispatcher definition
const method_dispatcher = Dict{String,DataType}(
    "exit" => ExitNotification,
    "textDocument/didClose" => DidCloseTextDocumentNotification,
    "initialized" => InitializedNotification,
    "shutdown" => ShutdownRequest,
    "initialize" => InitializeRequest,
    "textDocument/didSave" => DidSaveTextDocumentNotification,
    "textDocument/didOpen" => DidOpenTextDocumentNotification,
    "workspace/diagnostic" => WorkspaceDiagnosticRequest,
    "textDocument/didChange" => DidChangeTextDocumentNotification,
)
export
    method_dispatcher,
    ##AnonymousType#230,
    ##AnonymousType#231,
    ##AnonymousType#232,
    ##AnonymousType#233,
    ##AnonymousType#234,
    ##AnonymousType#235,
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
    DocumentDiagnosticReportKind,
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