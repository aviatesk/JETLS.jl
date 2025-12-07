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
    save::Union{Bool, SaveOptions, Nothing} = nothing
end

# Notebook Document Synchronization
# ==================================

"""
A notebook cell kind.

# Tags
- since - 3.17.0
"""
@namespace NotebookCellKind::Int begin
    "A markup-cell is formatted source that is used for display."
    Markup = 1

    "A code-cell is source code."
    Code = 2
end

"""
Execution summary information for a notebook cell.

# Tags
- since - 3.17.0
"""
@interface ExecutionSummary begin
    """
    A strict monotonically increasing value
    indicating the execution order of a cell
    inside a notebook.
    """
    executionOrder::UInt

    "Whether the execution was successful or not if known by the client."
    success::Union{Nothing, Bool} = nothing
end

"""
A notebook cell.

A cell's document URI must be unique across ALL notebook
cells and can therefore be used to uniquely identify a
notebook cell or the cell's text document.

# Tags
- since - 3.17.0
"""
@interface NotebookCell begin
    "The cell's kind"
    kind::NotebookCellKind.Ty

    "The URI of the cell's text document content."
    document::DocumentUri

    "Additional metadata stored with the cell."
    metadata::Union{Nothing, LSPObject} = nothing

    "Additional execution summary information if supported by the client."
    executionSummary::Union{Nothing, ExecutionSummary} = nothing
end

"""
A notebook document.

# Tags
- since - 3.17.0
"""
@interface NotebookDocument begin
    "The notebook document's URI."
    uri::URI

    "The type of the notebook."
    notebookType::String

    """
    The version number of this document (it will increase after each
    change, including undo/redo).
    """
    version::Int

    "Additional metadata stored with the notebook document."
    metadata::Union{Nothing, LSPObject} = nothing

    "The cells of a notebook."
    cells::Vector{NotebookCell}
end

"""
A notebook document filter denotes a notebook document by
different properties.

# Tags
- since - 3.17.0
"""
@interface NotebookDocumentFilter begin
    "The type of the enclosing notebook."
    notebookType::Union{Nothing, String} = nothing

    "A Uri scheme, like `file` or `untitled`."
    scheme::Union{Nothing, String} = nothing

    "A glob pattern."
    pattern::Union{Nothing, String} = nothing
end

"""
A notebook cell text document filter denotes a cell text
document by different properties.

# Tags
- since - 3.17.0
"""
@interface NotebookCellTextDocumentFilter begin
    """
    A filter that matches against the notebook
    containing the notebook cell. If a string
    value is provided it matches against the
    notebook type. '*' matches every notebook.
    """
    notebook::Union{String, NotebookDocumentFilter}

    """
    A language id like `python`.

    Will be matched against the language id of the
    notebook cell document. '*' matches every language.
    """
    language::Union{Nothing, String} = nothing
end

"""
A literal to identify a notebook document in the client.

# Tags
- since - 3.17.0
"""
@interface NotebookDocumentIdentifier begin
    "The notebook document's URI."
    uri::URI
end

"""
A versioned notebook document identifier.

# Tags
- since - 3.17.0
"""
@interface VersionedNotebookDocumentIdentifier begin
    "The version number of this notebook document."
    version::Int

    "The notebook document's URI."
    uri::URI
end

# Server Capabilities
# -------------------

@interface NotebookDocumentSyncOptionsNotebookSelectorCellsItem begin
    language::String
end

@interface NotebookDocumentSyncOptionsNotebookSelectorItem begin
    """
    The notebook to be synced. If a string
    value is provided it matches against the
    notebook type. '*' matches every notebook.
    """
    notebook::Union{Nothing, String, NotebookDocumentFilter} = nothing

    "The cells of the matching notebook to be synced."
    cells::Union{Nothing, Vector{NotebookDocumentSyncOptionsNotebookSelectorCellsItem}} = nothing
end

"""
Options specific to a notebook plus its cells to be synced to the server.

If a selector provides a notebook document filter but no cell selector all cells of a
matching notebook document will be synced.

If a selector provides no notebook document filter but only a cell selector all notebook
documents that contain at least one matching cell will be synced.

# Tags
- since - 3.17.0
"""
@interface NotebookDocumentSyncOptions begin
    "The notebooks to be synced."
    notebookSelector::Vector{NotebookDocumentSyncOptionsNotebookSelectorItem}

    """
    Whether save notification should be forwarded to
    the server. Will only be honored if mode === `notebook`.
    """
    save::Union{Nothing, Bool} = nothing
end

"""
Registration options specific to a notebook.

# Tags
- since - 3.17.0
"""
@interface NotebookDocumentSyncRegistrationOptions @extends NotebookDocumentSyncOptions, StaticRegistrationOptions begin
end

# Notifications
# -------------

"""
The params sent in an open notebook document notification.

# Tags
- since - 3.17.0
"""
@interface DidOpenNotebookDocumentParams begin
    "The notebook document that got opened."
    notebookDocument::NotebookDocument

    "The text documents that represent the content of a notebook cell."
    cellTextDocuments::Vector{TextDocumentItem}
end

"""
The open notification is sent from the client to the server when a notebook document
is opened. It is only sent by a client if the server requested the synchronization
mode `notebook` in its `notebookDocumentSync` capability.
"""
@interface DidOpenNotebookDocumentNotification @extends NotificationMessage begin
    method::String = "notebookDocument/didOpen"
    params::DidOpenNotebookDocumentParams
end

"""
A change describing how to move a `NotebookCell`
array from state S to S'.

# Tags
- since - 3.17.0
"""
@interface NotebookCellArrayChange begin
    "The start offset of the cell that changed."
    start::UInt

    "The deleted cells."
    deleteCount::UInt

    "The new cells, if any."
    cells::Union{Nothing, Vector{NotebookCell}} = nothing
end

@interface NotebookDocumentChangeEventCellsStructure begin
    "The change to the cell array."
    array::NotebookCellArrayChange

    "Additional opened cell text documents."
    didOpen::Union{Nothing, Vector{TextDocumentItem}} = nothing

    "Additional closed cell text documents."
    didClose::Union{Nothing, Vector{TextDocumentIdentifier}} = nothing
end

@interface NotebookDocumentChangeEventCellsTextContentItem begin
    document::VersionedTextDocumentIdentifier
    changes::Vector{TextDocumentContentChangeEvent}
end

@interface NotebookDocumentChangeEventCells begin
    "Changes to the cell structure to add or remove cells."
    structure::Union{Nothing, NotebookDocumentChangeEventCellsStructure} = nothing

    """
    Changes to notebook cells properties like its
    kind, execution summary or metadata.
    """
    data::Union{Nothing, Vector{NotebookCell}} = nothing

    "Changes to the text content of notebook cells."
    textContent::Union{Nothing, Vector{NotebookDocumentChangeEventCellsTextContentItem}} = nothing
end

"""
A change event for a notebook document.

# Tags
- since - 3.17.0
"""
@interface NotebookDocumentChangeEvent begin
    "The changed meta data if any."
    metadata::Union{Nothing, LSPObject} = nothing

    "Changes to cells."
    cells::Union{Nothing, NotebookDocumentChangeEventCells} = nothing
end

"""
The params sent in a change notebook document notification.

# Tags
- since - 3.17.0
"""
@interface DidChangeNotebookDocumentParams begin
    """
    The notebook document that did change. The version number points
    to the version after all provided changes have been applied.
    """
    notebookDocument::VersionedNotebookDocumentIdentifier

    """
    The actual changes to the notebook document.

    The change describes single state change to the notebook document.
    So it moves a notebook document, its cells and its cell text document
    contents from state S to S'.

    To mirror the content of a notebook using change events use the
    following approach:
    - start with the same initial content
    - apply the 'notebookDocument/didChange' notifications in the order
      you receive them.
    """
    change::NotebookDocumentChangeEvent
end

"""
The change notification is sent from the client to the server when a notebook document
changes. It is only sent by a client if the server requested the synchronization mode
`notebook` in its `notebookDocumentSync` capability.
"""
@interface DidChangeNotebookDocumentNotification @extends NotificationMessage begin
    method::String = "notebookDocument/didChange"
    params::DidChangeNotebookDocumentParams
end

"""
The params sent in a save notebook document notification.

# Tags
- since - 3.17.0
"""
@interface DidSaveNotebookDocumentParams begin
    "The notebook document that got saved."
    notebookDocument::NotebookDocumentIdentifier
end

"""
The save notification is sent from the client to the server when a notebook document
is saved. It is only sent by a client if the server requested the synchronization mode
`notebook` in its `notebookDocumentSync` capability.
"""
@interface DidSaveNotebookDocumentNotification @extends NotificationMessage begin
    method::String = "notebookDocument/didSave"
    params::DidSaveNotebookDocumentParams
end

"""
The params sent in a close notebook document notification.

# Tags
- since - 3.17.0
"""
@interface DidCloseNotebookDocumentParams begin
    "The notebook document that got closed."
    notebookDocument::NotebookDocumentIdentifier

    "The text documents that represent the content of a notebook cell that got closed."
    cellTextDocuments::Vector{TextDocumentIdentifier}
end

"""
The close notification is sent from the client to the server when a notebook document
is closed. It is only sent by a client if the server requested the synchronization mode
`notebook` in its `notebookDocumentSync` capability.
"""
@interface DidCloseNotebookDocumentNotification @extends NotificationMessage begin
    method::String = "notebookDocument/didClose"
    params::DidCloseNotebookDocumentParams
end
