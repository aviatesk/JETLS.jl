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

    # """
    # Capabilities specific to the `textDocument/definition` request.
    # """
    # definition::Union{DefinitionClientCapabilities, Nothing} = nothing

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

        # """
        # Capabilities specific to the `workspace/executeCommand` request.
        # """
        # executeCommand::Union{ExecuteCommandClientCapabilities, Nothing} = nothing

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

    # "Text document specific client capabilities."
    # textDocument::Union{TextDocumentClientCapabilities, Nothing} = nothing

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

        # """
        # Client capabilities for the show document request.

        # # Tags
        # - since – 3.16.0
        # """
        # showDocument::Union{ShowDocumentClientCapabilities, Nothing} = nothing
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
