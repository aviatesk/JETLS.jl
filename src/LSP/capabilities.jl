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

    "Experimental client capabilities."
    experimental::Union{Any, Nothing} = nothing
end
