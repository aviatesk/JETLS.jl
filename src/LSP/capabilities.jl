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

@interface TextDocumentClientCapabilities begin
    # "Capabilities specific to text document synchronization."
    # synchronization::Union{TextDocumentSyncClientCapabilities, Nothing} = nothing

    """
    Capabilities specific to the `textDocument/completion` request.
    """
    completion::Union{CompletionClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/hover` request.
    # """
    # hover::Union{HoverClientCapabilities, Nothing} = nothing

    # """
    # Capabilities specific to the `textDocument/signatureHelp` request.
    # """
    # signatureHelp::Union{SignatureHelpClientCapabilities, Nothing} = nothing

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

@interface ClientCapabilities begin
    "Workspace specific client capabilities."
    workspace::Union{Nothing, @interface begin
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
        fileOperations::Union{Nothing, @interface begin
            """
            Whether the client supports dynamic registration for file requests/notifications.
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
    end} = nothing

    "Text document specific client capabilities."
    textDocument::Union{TextDocumentClientCapabilities, Nothing} = nothing;

    "Experimental client capabilities."
    experimental::Union{Any, Nothing} = nothing
end
