# Publish diagnostics
# ===================

"""
Diagnostics notifications are sent from the server to the client to signal
results of validation runs.

Diagnostics are "owned" by the server so it is the server's responsibility to clear them
if necessary. The following rule is used for VS Code servers that generate diagnostics:

- if a language is single file only (for example HTML) then diagnostics are cleared by the
  server when the file is closed. Please note that open / close events don't necessarily
  reflect what the user sees in the user interface. These events are ownership events. So
  with the current version of the specification it is possible that problems are not
  cleared although the file is not visible in the user interface since the client has not
  closed the file yet.
- if a language has a project system (for example C#) diagnostics are not cleared when a
  file closes. When a project is opened all diagnostics for all files are recomputed (or
  read from a cache).

When a file changes it is the server's responsibility to re-compute diagnostics and push
them to the client. If the computed set is empty it has to push the empty array to clear
former diagnostics. Newly pushed diagnostics always replace previously pushed diagnostics.
There is no merging that happens on the client side.

See also the [Diagnostic](@ref diagnostic) section.
"""

@interface PublishDiagnosticsClientCapabilities begin
    """
    Whether the clients accepts diagnostics with related information.
    """
    relatedInformation::Union{Nothing, Bool} = nothing

    """
    Client supports the tag property to provide meta data about a diagnostic.
    Clients supporting tags have to handle unknown tags gracefully.

    # Tags
    - since - 3.15.0
    """
    tagSupport::Union{Nothing, @interface begin
        """
        The tags supported by the client.
        """
        valueSet::Vector{DiagnosticTag.Ty}
    end} = nothing

    """
    Whether the client interprets the version property of the
    `textDocument/publishDiagnostics` notification's parameter.

    # Tags
    - since - 3.15.0
    """
    versionSupport::Union{Nothing, Bool} = nothing

    """
    Client supports a codeDescription property

    # Tags
    - since - 3.16.0
    """
    codeDescriptionSupport::Union{Nothing, Bool} = nothing

    """
    Whether code action supports the `data` property which is
    preserved between a `textDocument/publishDiagnostics` and
    `textDocument/codeAction` request.

    # Tags
    - since - 3.16.0
    """
    dataSupport::Union{Nothing, Bool} = nothing
end

@interface PublishDiagnosticsParams begin
    """
    The URI for which diagnostic information is reported.
    """
    uri::DocumentUri

    """
    Optional the version number of the document the diagnostics are published for.

    # Tags
    - since - 3.15.0
    """
    version::Union{Nothing, Int} = nothing

    """
    An array of diagnostic information items.
    """
    diagnostics::Vector{Diagnostic}
end

@interface PublishDiagnosticsNotification @extends NotificationMessage begin
    method::String = "textDocument/publishDiagnostics"
    params::PublishDiagnosticsParams
end

# Pull diagnostics
# ================

"""
Diagnostics are currently published by the server to the client using a
notification. This model has the advantage that for workspace wide diagnostics
the server has the freedom to compute them at a server preferred point in
time. On the other hand the approach has the disadvantage that the server
can't prioritize the computation for the file in which the user types or
which are visible in the editor. Inferring the client's UI state from the
[`textDocument/didOpen`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_didOpen)
and [`textDocument/didChange`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_didChange)
notifications might lead to false positives since these notifications are
ownership transfer notifications.

The specification therefore introduces the concept of diagnostic pull requests
to give a client more control over the documents for which diagnostics should
be computed and at which point in time.
"""

# Document diagnostics
# --------------------

"""
Client capabilities specific to diagnostic pull requests.

# Tags
- since - 3.17.0
"""
@interface DiagnosticClientCapabilities begin
    """
    Whether implementation supports dynamic registration. If this is set to
    `true` the client supports the new
    `(TextDocumentRegistrationOptions & StaticRegistrationOptions)`
    return value for the corresponding server capability as well.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing

    """
    Whether the clients supports related documents for document diagnostic
    pulls.
    """
    relatedDocumentSupport::Union{Nothing, Bool} = nothing
end

"""
Diagnostic options.

# Tags
- since - 3.17.0
"""
@interface DiagnosticOptions @extends WorkDoneProgressOptions begin
    """
    An optional identifier under which the diagnostics are
    managed by the client.
    """
    identifier::Union{Nothing, String} = nothing

    """
    Whether the language has inter file dependencies meaning that
    editing code in one file can result in a different diagnostic
    set in another file. Inter file dependencies are common for
    most programming languages and typically uncommon for linters.
    """
    interFileDependencies::Bool

    """
    The server provides support for workspace diagnostics as well.
    """
    workspaceDiagnostics::Bool
end

"""
Diagnostic registration options.

# Tags
- since - 3.17.0
"""
@interface DiagnosticRegistrationOptions @extends TextDocumentRegistrationOptions, DiagnosticOptions, StaticRegistrationOptions begin
end

"""
Parameters of the document diagnostic request.

# Tags
- since – 3.17.0
"""
@interface DocumentDiagnosticParams @extends WorkDoneProgressParams,
PartialResultParams begin
    "The text document."
    textDocument::TextDocumentIdentifier

    "The additional identifier provided during registration."
    identifier::Union{String, Nothing} = nothing

    "The result id of a previous response if provided."
    previousResultId::Union{String, Nothing} = nothing
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

"""A diagnostic report with a full set of problems.

# Tags
- since – 3.17.0
"""
@interface FullDocumentDiagnosticReport begin
    "A full document diagnostic report."
    kind::DocumentDiagnosticReportKind.Ty = DocumentDiagnosticReportKind.Full

    """
    An optional result id. If provided it will be sent on the next diagnostic request
    for the same document.
    """
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
    """
    A document diagnostic report indicating no changes to the last result.
    A server can only return `unchanged` if result ids are provided.
    """
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
    relatedDocuments::Union{Dict{DocumentUri, Union{FullDocumentDiagnosticReport, UnchangedDocumentDiagnosticReport}}, Nothing} = nothing
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
    relatedDocuments::Union{Dict{DocumentUri, Union{FullDocumentDiagnosticReport, UnchangedDocumentDiagnosticReport}}, Nothing} = nothing
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
A partial result for a document diagnostic report.

# Tags
- since - 3.17.0
"""
@interface DocumentDiagnosticReportPartialResult begin
    relatedDocuments::Dict{DocumentUri, Union{FullDocumentDiagnosticReport, UnchangedDocumentDiagnosticReport}}
end

"""
The text document diagnostic request is sent from the client to the server to ask the server
to compute the diagnostics for a given document. As with other pull requests the server
is asked to compute the diagnostics for the currently synced version of the document.
"""
@interface DocumentDiagnosticRequest @extends RequestMessage begin
    method::String = "textDocument/diagnostic"
    params::DocumentDiagnosticParams
end

"""
- result: [`DocumentDiagnosticReport`](@ref).
- partial result: The first literal send need to be a [`DocumentDiagnosticReport`](@ref)
  followed by n [`DocumentDiagnosticReportPartialResult`](@ref) literals.
- error: code and message set in case an exception happens during the diagnostic request.
  A server is also allowed to return an error with code [`ServerCancelled`](@ref) indicating
  that the server can't compute the result right now. A server can return a
  [`DiagnosticServerCancellationData`](@ref) data to indicate whether the client should
  re-trigger the request. If no data is provided it defaults to `{ retriggerRequest: true }`.
"""
@interface DocumentDiagnosticResponse @extends ResponseMessage begin
    result::Union{DocumentDiagnosticReport, Nothing}
end

"""
Cancellation data returned from a diagnostic request.

# Tags
- since – 3.17.0
"""
@interface DiagnosticServerCancellationData begin
    retriggerRequest::Bool
end

# Workspace diagnostics
# ---------------------

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

    "The currently known diagnostic reports with their previous result ids."
    previousResultIds::Vector{PreviousResultId}
end

"""
The workspace diagnostic request is sent from the client to the server to ask the server to
compute workspace wide diagnostics which previously were pushed from the server to the
client. In contrast to the document diagnostic request the workspace request can be long
running and is not bound to a specific workspace or document state. If the client supports
streaming for the workspace diagnostic pull it is legal to provide a document diagnostic
report multiple times for the same document URI. The last one reported will win over previous
reports.

If a client receives a diagnostic report for a document in a workspace diagnostic request
for which the client also issues individual document diagnostic pull requests the client
needs to decide which diagnostics win and should be presented. In general:

- diagnostics for a higher document version should win over those from a lower document
    version (e.g. note that document versions are steadily increasing)
- diagnostics from a document pull should win over diagnostics from a workspace pull.
"""
@interface WorkspaceDiagnosticRequest @extends RequestMessage begin
    method::String = "workspace/diagnostic"
    params::WorkspaceDiagnosticParams
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
    version::Union{Int, Null}
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
    version::Union{Int, Null}
end

"""
A workspace diagnostic document report.

# Tags
- since – 3.17.0
"""
const WorkspaceDocumentDiagnosticReport =
    Union{WorkspaceFullDocumentDiagnosticReport, WorkspaceUnchangedDocumentDiagnosticReport}
export WorkspaceDocumentDiagnosticReport

@interface WorkspaceDiagnosticReport begin
    items::Vector{WorkspaceDocumentDiagnosticReport}
end

"""
A partial result for a workspace diagnostic report.

# Tags
- since - 3.17.0
"""
@interface WorkspaceDiagnosticReportPartialResult begin
    items::Vector{WorkspaceDocumentDiagnosticReport}
end

"""
- result: [`WorkspaceDiagnosticReport`](@ref).
- partial result: The first literal send need to be a [`WorkspaceDiagnosticReport`](@ref)
  followed by n [`WorkspaceDiagnosticReportPartialResult`](@ref) literals.
- error: code and message set in case an exception happens during the diagnostic request.
  A server is also allowed to return an error with code [`ServerCancelled`](@ref) indicating
  that the server can't compute the result right now. A server can return a
  [`DiagnosticServerCancellationData`](@ref) data to indicate whether the client should
  re-trigger the request. If no data is provided it defaults to `{ retriggerRequest: true }`.
"""
@interface WorkspaceDiagnosticResponse @extends ResponseMessage begin
    result::Union{WorkspaceDiagnosticReport, Nothing}
end

# Diagnostics Refresh
# -------------------

"""
Workspace client capabilities specific to diagnostic pull requests.

# Tags
- since - 3.17.0
"""
@interface DiagnosticWorkspaceClientCapabilities begin
    """
    Whether the client implementation supports a refresh request sent from
    the server to the client.

    Note that this event is global and will force the client to refresh all
    pulled diagnostics currently shown. It should be used with absolute care
    and is useful for situation where a server for example detects a project
    wide change that requires such a calculation.
    """
    refreshSupport::Union{Nothing, Bool} = nothing
end

"""
The `workspace/diagnostic/refresh` request is sent from the server to the client. Servers
can use it to ask clients to refresh all needed document and workspace diagnostics. This is
useful if a server detects a project wide configuration change which requires a re-calculation
of all diagnostics.
"""
@interface WorkspaceDiagnosticRefreshRequest @extends RequestMessage begin
    method::String = "workspace/diagnostic/refresh"
    params::Nothing = nothing
end

"""
- result: void
- error: code and message set in case an exception happens during the
  'workspace/diagnostic/refresh' request
"""
@interface WorkspaceDiagnosticRefreshResponse @extends ResponseMessage begin
    result::Union{Null, Nothing}
end

# Implementation Considerations
# -----------------------------

"""
Generally the language server specification doesn't enforce any specific client implementation
since those usually depend on how the client UI behaves. However since diagnostics can be
provided on a document and workspace level here are some tips:

- a client should pull actively for the document the users types in.
- if the server signals inter file dependencies a client should also pull for visible documents
  to ensure accurate diagnostics. However the pull should happen less frequently.
- if the server signals workspace pull support a client should also pull for workspace
  diagnostics. It is recommended for clients to implement partial result progress for the
  workspace pull to allow servers to keep the request open for a long time. If a server closes
  a workspace diagnostic pull request the client should re-trigger the request.
"""
