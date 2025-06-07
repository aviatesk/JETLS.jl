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

    completionProvider::Union{CompletionOptions, Nothing} = nothing

    signatureHelpProvider::Union{SignatureHelpOptions, Nothing} = nothing

    definitionProvider::Union{Union{DefinitionOptions, Bool}, Nothing} = nothing

    "Workspace specific server capabilities"
    workspace::Union{Nothing, @interface begin
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
        fileOperations::Union{Nothing, @interface begin
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

"""
`TextDocumentClientCapabilities` define capabilities the editor / tool provides on text documents.
"""
@interface TextDocumentClientCapabilities begin
    # synchronization::Union{TextDocumentSyncClientCapabilities, Nothing} = nothing

    """
    Capabilities specific to the `textDocument/completion` request.
    """
    completion::Union{CompletionClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/hover` request.
    # """
    # hover::Union{HoverClientCapabilities, Nothing} = nothing

    """
    Capabilities specific to the `textDocument/signatureHelp` request.
    """
    signatureHelp::Union{SignatureHelpClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/declaration` request.

    # # Tags
    # - since – 3.14.0
    # """
    # declaration::Union{DeclarationClientCapabilities, Nothing} = nothing

    """
    Capabilities specific to the `textDocument/definition` request.
    """
    definition::Union{DefinitionClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/typeDefinition` request.

    # # Tags
    # - since – 3.6.0
    # """
    # typeDefinition::Union{TypeDefinitionClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/implementation` request.

    # # Tags
    # - since – 3.6.0
    # """
    # implementation::Union{ImplementationClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/references` request.
    # """
    # references::Union{ReferenceClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/documentHighlight` request.
    # """
    # documentHighlight::Union{DocumentHighlightClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/documentSymbol` request.
    # """
    # documentSymbol::Union{DocumentSymbolClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/codeAction` request.
    # """
    # codeAction::Union{CodeActionClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/codeLens` request.
    # """
    # codeLens::Union{CodeLensClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/documentLink` request.
    # """
    # documentLink::Union{DocumentLinkClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/documentColor` and the
    # `textDocument/colorPresentation` request.

    # # Tags
    # - since – 3.6.0
    # """
    # colorProvider::Union{DocumentColorClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/formatting` request.
    # """
    # formatting::Union{DocumentFormattingClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/rangeFormatting` request.
    # """
    # rangeFormatting::Union{DocumentRangeFormattingClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/onTypeFormatting` request.
    # """
    # onTypeFormatting::Union{DocumentOnTypeFormattingClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/rename` request.
    # """
    # rename::Union{RenameClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/publishDiagnostics` notification.
    # """
    # publishDiagnostics::Union{PublishDiagnosticsClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/foldingRange` request.

    # # Tags
    # - since – 3.10.0
    # """
    # foldingRange::Union{FoldingRangeClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/selectionRange` request.

    # # Tags
    # - since – 3.15.0
    # """
    # selectionRange::Union{SelectionRangeClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/linkedEditingRange` request.

    # # Tags
    # - since – 3.16.0
    # """
    # linkedEditingRange::Union{LinkedEditingRangeClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the various call hierarchy requests.

    # # Tags
    # - since – 3.16.0
    # """
    # callHierarchy::Union{CallHierarchyClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the various semantic token requests.

    # # Tags
    # - since – 3.16.0
    # """
    # semanticTokens::Union{SemanticTokensClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/moniker` request.

    # # Tags
    # - since – 3.16.0
    # """
    # moniker::Union{MonikerClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the various type hierarchy requests.

    # # Tags
    # - since – 3.17.0
    # """
    # typeHierarchy::Union{TypeHierarchyClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/inlineValue` request.

    # # Tags
    # - since – 3.17.0
    # """
    # inlineValue::Union{InlineValueClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/inlayHint` request.

    # # Tags
    # - since – 3.17.0
    # """
    # inlayHint::Union{InlayHintClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the diagnostic pull model.

    # # Tags
    # - since – 3.17.0
    # """
    # diagnostic::Union{DiagnosticClientCapabilities, Nothing} = nothing
end

"""
`ClientCapabilities` define capabilities for dynamic registration, workspace and text
document features the client supports. The `experimental` can be used to pass
experimental capabilities under development. For future compatibility a
`ClientCapabilities` object literal can have more properties set than currently defined.
Servers receiving a `ClientCapabilities` object literal with unknown properties should
ignore these properties. A missing property should be interpreted as an absence of the
capability. If a missing property normally defines sub properties, all missing sub
properties should be interpreted as an absence of the corresponding capability.

Client capabilities got introduced with version 3.0 of the protocol. They therefore
only describe capabilities that got introduced in 3.x or later. Capabilities that
existed in the 2.x version of the protocol are still mandatory for clients. Clients
cannot opt out of providing them. So even if a client omits the
`ClientCapabilities.textDocument.synchronization` it is still required that the client
provides text document synchronization (e.g. open, changed and close notifications).
"""
@interface ClientCapabilities begin
    "Workspace specific client capabilities."
    workspace::Union{Nothing, @interface begin
        """
        The client supports applying batch edits
        to the workspace by supporting the request
        'workspace/applyEdit'
        """
        applyEdit::Union{Bool, Nothing} = nothing

        # """
        # Capabilities specific to `WorkspaceEdit`s
        # """
        # workspaceEdit::Union{WorkspaceEditClientCapabilities, Nothing} = nothing

        # """
        # Capabilities specific to the `workspace/didChangeConfiguration`
        # notification.
        # """
        # didChangeConfiguration::Union{DidChangeConfigurationClientCapabilities, Nothing} = nothing

        # """
        # Capabilities specific to the `workspace/didChangeWatchedFiles`
        # notification.
        # """
        # didChangeWatchedFiles::Union{DidChangeWatchedFilesClientCapabilities, Nothing} = nothing

        # """
        # Capabilities specific to the `workspace/symbol` request.
        # """
        # symbol::Union{WorkspaceSymbolClientCapabilities, Nothing} = nothing

        """
        Capabilities specific to the `workspace/executeCommand` request.
        """
        executeCommand::Union{ExecuteCommandClientCapabilities, Nothing} = nothing

        """
        The client has support for workspace folders.

        # Tags
        - since – 3.6.0
        """
        workspaceFolders::Union{Bool, Nothing} = nothing

        """
        The client supports `workspace/configuration` requests.

        # Tags
        - since – 3.6.0
        """
        configuration::Union{Bool, Nothing} = nothing

        # """
        # Capabilities specific to the semantic token requests scoped to the
        # workspace.

        # # Tags
        # - since – 3.16.0
        # """
        # semanticTokens::Union{SemanticTokensWorkspaceClientCapabilities, Nothing} = nothing

        # """
        # Capabilities specific to the code lens requests scoped to the
        # workspace.

        # # Tags
        # - since – 3.16.0
        # """
        # codeLens::Union{CodeLensWorkspaceClientCapabilities, Nothing} = nothing

        """
        # The client has support for file requests/notifications.

        # Tags
        - since – 3.16.0
        """
        fileOperations::Union{Nothing, @interface begin
            """
            Whether the client supports dynamic registration for file
            requests/notifications.
            """
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

        # """
        # Client workspace capabilities specific to inline values.

        # # Tags
        # - since – 3.17.0
        # """
        # inlineValue::Union{InlineValueWorkspaceClientCapabilities, Nothing} = nothing

        # """
        # Client workspace capabilities specific to inlay hints.

        # # Tags
        # - since – 3.17.0
        # """
        # inlayHint::Union{InlayHintWorkspaceClientCapabilities, Nothing} = nothing

        # """
        # Client workspace capabilities specific to diagnostics.

        # # Tags
        # - since – 3.17.0.
        # """
        # diagnostics::Union{DiagnosticWorkspaceClientCapabilities, Nothing} = nothing
    end} = nothing

    "Text document specific client capabilities."
    textDocument::Union{TextDocumentClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the notebook document support.

    # # Tags
    # - since – 3.17.0
    # """
    # notebookDocument::Union{NotebookDocumentClientCapabilities, Nothing} = nothing

    "Window specific client capabilities."
    window::Union{Nothing, @interface begin
        """
        It indicates whether the client supports server initiated
        progress using the `window/workDoneProgress/create` request.

        The capability also controls Whether client supports handling
        of progress notifications. If set servers are allowed to report a
        `workDoneProgress` property in the request specific server
        capabilities.

        # Tags
        - since – 3.15.0
        """
        workDoneProgress::Union{Bool, Nothing} = nothing

        # """
        # Capabilities specific to the showMessage request

        # # Tags
        # - since – 3.16.0
        # """
        # showMessage::Union{ShowMessageRequestClientCapabilities, Nothing} = nothing

        """
        Client capabilities for the show document request.

        # Tags
        - since – 3.16.0
        """
        showDocument::Union{ShowDocumentClientCapabilities, Nothing} = nothing
    end} = nothing

    """
    General client capabilities.

    # Tags
    - since – 3.16.0
    """
    general::Union{Nothing, @interface begin
        """
        Client capability that signals how the client
        handles stale requests (e.g. a request
        for which the client will not process the response
        anymore since the information is outdated).

        # Tags
        - since – 3.17.0
        """
        staleRequestSupport::Union{Nothing, @interface begin
            "The client will actively cancel the request."
            cancel::Bool

            """
            The list of requests for which the client
            will retry the request if it receives a
            response with error code `ContentModified`
            """
            retryOnContentModified::Vector{String}
        end} = nothing

        # """
        # Client capabilities specific to regular expressions.

        # # Tags
        # - since – 3.16.0
        # """
        # regularExpressions::Union{RegularExpressionsClientCapabilities, Nothing} = nothing

        # """
        # Client capabilities specific to the client's markdown parser.

        # # Tags
        # - since – 3.16.0
        # """
        # markdown::Union{MarkdownClientCapabilities, Nothing} = nothing

        """
        The position encodings supported by the client. Client and server
        have to agree on the same position encoding to ensure that offsets
        (e.g. character position in a line) are interpreted the same on both
        side.

        To keep the protocol backwards compatible the following applies: if
        the value 'utf-16' is missing from the array of position encodings
        servers can assume that the client supports UTF-16. UTF-16 is
        therefore a mandatory encoding.

        If omitted it defaults to ['utf-16'].

        Implementation considerations: since the conversion from one encoding
        into another requires the content of the file / line the conversion
        is best done where the file is read which is usually on the server
        side.

        # Tags
        - since – 3.17.0
        """
        positionEncodings::Union{Vector{PositionEncodingKind.Ty}, Nothing} = nothing
    end} = nothing

    "Experimental client capabilities."
    experimental::Union{Any, Nothing} = nothing
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

    Uses IETF language tags as the value's syntax
    (see https://en.wikipedia.org/wiki/IETF_language_tag).

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
If the server receives a request or notification before the initialize request it should act
as follows:
   - For a request the response should be an error with code: -32002. The message
     can be picked by the server.
   - Notifications should be dropped, except for the exit notification. This will allow
     the exit of a server without an initialize request.

Until the server has responded to the initialize request with an `InitializeResult`,
the client must not send any additional requests or notifications to the server.
In addition the server is not allowed to send any requests or notifications to the client
until it has responded with an `InitializeResult`, with the exception that during the
initialize request the server is allowed to send the notifications `window/showMessage`,
`window/logMessage` and `telemetry/event` as well as the `window/showMessageRequest`
request to the client. In case the client sets up a progress token in the initialize params
(e.g. property `workDoneToken`) the server is also allowed to use that token
(and only that token) using the `\$/progress` notification sent from the server to the
client.
The initialize request may only be sent once.
"""
@interface InitializeRequest @extends RequestMessage begin
    method::String = "initialize"
    params::InitializeParams
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

"Known error codes for an `InitializeErrorCodes`."
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
    (1) show the message provided by the ResponseError to the user;
    (2) user selects retry or cancel;
    (3) if user selected retry the initialize method is sent again.
    """
    retry::Bool
end

@interface InitializeResponseError @extends ResponseError begin
    code::InitializeErrorCodes.Ty
    data::InitializeError
end

@interface InitializeResponse @extends ResponseMessage begin
    result::Union{InitializeResult, Nothing}
    error::Union{InitializeResponseError, Nothing} = nothing
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
