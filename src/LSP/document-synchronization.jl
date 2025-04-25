# Text document
# =============

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

# Open
# ----

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

# Change
# ------

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

# Save
# ----

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

# Close
# -----

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

# Rename
# ------

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
