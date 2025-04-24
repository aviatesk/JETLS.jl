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

@namespace DiagnosticSeverity::Int begin
    "Reports an error."
    Error = 1

    "Reports a warning."
    Warning = 2

    "Reports an information."
    Information = 3

    "Reports a hint."
    Hint = 4
end

"""
Structure to capture a description for an error code.

# Tags
- since – 3.16.0
"""
@interface CodeDescription begin
    "An URI to open with more information about the diagnostic error."
    href::URI
end

"""
The diagnostic tags.

# Tags
- since – 3.15.0
"""
@namespace DiagnosticTag::Int begin
    """
    Unused or unnecessary code. Clients are allowed to render diagnostics with this tag
    faded out instead of having an error squiggle.
    """
    Unnecessary = 1

    """
    Deprecated or obsolete code. Clients are allowed to rendered diagnostics with this tag
    strike through.
    """
    Deprecated = 2
end

"""
Represents a location inside a resource, such as a line inside a text file.
"""
@interface Location begin
    uri::DocumentUri
    range::Range
end

"""
Represents a related message and source code location for a diagnostic.
This should be used to point to code locations that cause or are related to a diagnostics,
e.g when duplicating a symbol in a scope.
"""
@interface DiagnosticRelatedInformation begin
    "The location of this related diagnostic information."
    location::Location

    "The message of this related diagnostic information."
    message::String
end

@interface Diagnostic begin
    "The range at which the message applies."
    range::Range

    """
    The diagnostic's severity.
    To avoid interpretation mismatches when a server is used with different clients it is
    highly recommended that servers always provide a severity value.
    If omitted, it’s recommended for the client to interpret it as an Error severity.
    """
    severity::Union{DiagnosticSeverity.Ty, Nothing} = nothing

    "The diagnostic's code, which might appear in the user interface."
    code::Union{Union{Int, String}, Nothing} = nothing

    """
    An optional property to describe the error code.

    # Tags
    - since – 3.16.0
    """
    codeDescription::Union{CodeDescription, Nothing} = nothing

    """
    A human-readable string describing the source of this diagnostic, e.g. 'typescript'
    or 'super lint'.
    """
    source::Union{String, Nothing} = nothing

    "The diagnostic's message."
    message::String

    """
    Additional metadata about the diagnostic.

    # Tags
    - since – 3.15.0
    """
    tags::Union{Vector{DiagnosticTag.Ty}, Nothing} = nothing

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
Static registration options to be returned in the initialize request.
"""
@interface StaticRegistrationOptions begin
    """
    The id used to register the request. The id can be used to deregister the request again.
    See also Registration#id.
    """
    id::Union{String, Nothing} = nothing
end

"""
Diagnostic registration options.

# Tags
- since – 3.17.0
"""
@interface DiagnosticRegistrationOptions @extends TextDocumentRegistrationOptions,
DiagnosticOptions, StaticRegistrationOptions begin
end

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
The text document diagnostic request is sent from the client to the server to ask the server
to compute the diagnostics for a given document. As with other pull requests the server
is asked to compute the diagnostics for the currently synced version of the document.
"""
@interface DocumentDiagnosticRequest @extends RequestMessage begin
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
const DocumentDiagnosticReport =
    Union{RelatedFullDocumentDiagnosticReport, RelatedUnchangedDocumentDiagnosticReport}

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

@interface WorkspaceDiagnosticRequest @extends RequestMessage begin
    method::String = "workspace/diagnostic"
    params::WorkspaceDiagnosticParams
end
