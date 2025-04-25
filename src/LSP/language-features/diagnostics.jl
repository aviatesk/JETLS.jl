# Publish diagnostics
# ===================

@interface PublishDiagnosticsParams begin
    "The URI for which diagnostic information is reported."
    uri::DocumentUri

    """
    Optional the version number of the document the diagnostics are published for.

    @since 3.15.0
    """
    version::Union{Int,Nothing} = nothing

    "An array of diagnostic information items."
    diagnostics::Vector{Diagnostic}
end

@interface PublishDiagnosticsNotification @extends NotificationMessage begin
    method::String = "textDocument/publishDiagnostics"
    params::PublishDiagnosticsParams
end

# Pull diagnostics
# ================

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
    Inter file dependencies are common for most programming languages and typically uncommon
    for linters.
    """
    interFileDependencies::Bool

    "The server provides support for workspace diagnostics as well."
    workspaceDiagnostics::Bool
end

"""
Diagnostic registration options.

# Tags
- since – 3.17.0
"""
@interface DiagnosticRegistrationOptions @extends TextDocumentRegistrationOptions,
DiagnosticOptions, StaticRegistrationOptions begin
end

# Document diagnostics
# --------------------

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
    relatedDocuments::Union{Dict{DocumentUri,
                                 Union{FullDocumentDiagnosticReport,
                                       UnchangedDocumentDiagnosticReport}},
                            Nothing} = nothing
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
    relatedDocuments::Union{Dict{DocumentUri,
                                 Union{FullDocumentDiagnosticReport,
                                       UnchangedDocumentDiagnosticReport}},
                            Nothing} = nothing
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
The text document diagnostic request is sent from the client to the server to ask the server
to compute the diagnostics for a given document. As with other pull requests the server
is asked to compute the diagnostics for the currently synced version of the document.
"""
@interface DocumentDiagnosticRequest @extends RequestMessage begin
    method::String = "textDocument/diagnostic"
    params::DocumentDiagnosticParams
end

@interface DocumentDiagnosticResponse @extends ResponseMessage begin
    result::Union{DocumentDiagnosticReport, Nothing} = nothing
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
@interface WorkspaceDiagnosticParams @extends WorkDoneProgressParams,
PartialResultParams begin
    "The additional identifier provided during registration."
    identifier::Union{String, Nothing} = nothing

    "The currently known diagnostic reports with their\nprevious result ids."
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
