@doc "Defines an integer number in the range of -2^31 to 2^31 - 1." integer

@doc "Defines an unsigned integer number in the range of 0 to 2^31 - 1." uinteger

@doc "Defines a decimal number. Since decimal numbers are very\nrare in the language server specification we denote the\nexact range with every decimal using the mathematics\ninterval notation (e.g. [0, 1] denotes all decimals d with\n0 <= d <= 1." decimal

@doc "The LSP any type\n\n# Tags\n\n- since – 3.17.0" LSPAny

@doc "LSP object definition.\n\n# Tags\n\n- since – 3.17.0" LSPObject

@doc "LSP arrays.\n\n# Tags\n\n- since – 3.17.0" LSPArray

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
@kwdef struct SaveOptions
        "The client is supposed to include the content on save."
        includeText::Union{Bool, Nothing} = nothing
    end
StructTypes.omitempties(::Type{SaveOptions}) = begin
        (:includeText,)
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

@kwdef struct StaticRegistrationOptions
        "The id used to register the request. The id can be used to deregister\nthe request again. See also Registration#id."
        id::Union{String, Nothing} = nothing
    end
StructTypes.omitempties(::Type{StaticRegistrationOptions}) = begin
        (:id,)
    end
@doc "Static registration options to be returned in the initialize request." StaticRegistrationOptions

@kwdef struct TextDocumentRegistrationOptions
        "A document selector to identify the scope of the registration. If set to\nnull the document selector provided on the client side will be used."
        documentSelector::Union{lsptypeof(Val(:DocumentSelector)), Core.typeof(nothing)}
    end
@doc "General text document registration options." TextDocumentRegistrationOptions

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

@kwdef struct ServerCapabilities
        "The position encoding the server picked from the encodings offered\nby the client via the client capability `general.positionEncodings`.\n\nIf the client didn't provide any position encodings the only valid\nvalue that a server can return is 'utf-16'.\n\nIf omitted it defaults to 'utf-16'.\n\n# Tags\n\n- since – 3.17.0"
        positionEncoding::Union{lsptypeof(Val(:PositionEncodingKind)), Nothing} = nothing
        "Defines how text documents are synced. Is either a detailed structure\ndefining each notification or for backwards compatibility the\nTextDocumentSyncKind number. If omitted it defaults to\n`TextDocumentSyncKind.None`."
        textDocumentSync::Union{Union{TextDocumentSyncOptions, lsptypeof(Val(:TextDocumentSyncKind))}, Nothing} = nothing
        "The server has support for pull model diagnostics.\n\n# Tags\n\n- since – 3.17.0"
        diagnosticProvider::Union{Union{DiagnosticOptions, DiagnosticRegistrationOptions}, Nothing} = nothing
    end
StructTypes.omitempties(::Type{ServerCapabilities}) = begin
        (:positionEncoding, :textDocumentSync, :diagnosticProvider)
    end

@kwdef struct var"##AnonymousType#230"
        "The name of the server as defined by the server."
        name::String
        "The server's version as defined by the server."
        version::Union{String, Nothing} = nothing
    end
StructTypes.omitempties(::Type{var"##AnonymousType#230"}) = begin
        (:version,)
    end
Base.convert(::Type{var"##AnonymousType#230"}, nt::NamedTuple) = begin
        var"##AnonymousType#230"(; nt...)
    end
@kwdef struct InitializeResult
        "The capabilities the language server provides."
        capabilities::ServerCapabilities
        "Information about the server.\n\n# Tags\n\n- since – 3.15.0"
        serverInfo::Union{var"##AnonymousType#230", Nothing} = nothing
    end
StructTypes.omitempties(::Type{InitializeResult}) = begin
        (:serverInfo,)
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

export
    CodeDescription,
    Location,
    Position,
    WorkspaceUnchangedDocumentDiagnosticReport,
    WorkspaceFullDocumentDiagnosticReport,
    FullDocumentDiagnosticReport,
    uinteger,
    StaticRegistrationOptions,
    DocumentDiagnosticReportKind,
    LSPAny,
    LSPObject,
    SaveOptions,
    DocumentSelector,
    UnchangedDocumentDiagnosticReport,
    WorkspaceDiagnosticReport,
    TextDocumentSyncOptions,
    TextDocumentRegistrationOptions,
    ServerCapabilities,
    WorkspaceDocumentDiagnosticReport,
    URI,
    Diagnostic,
    DocumentUri,
    LSPArray,
    DocumentFilter,
    DiagnosticRegistrationOptions,
    DiagnosticTag,
    InitializeResult,
    DiagnosticRelatedInformation,
    Range,
    PositionEncodingKind,
    DiagnosticSeverity,
    decimal,
    TextDocumentSyncKind,
    integer,
    ##AnonymousType#230,
    WorkDoneProgressOptions,
    DiagnosticOptionsCodeDescription,
    Location,
    Position,
    WorkspaceUnchangedDocumentDiagnosticReport,
    WorkspaceFullDocumentDiagnosticReport,
    FullDocumentDiagnosticReport,
    StaticRegistrationOptions,
    SaveOptions,
    UnchangedDocumentDiagnosticReport,
    WorkspaceDiagnosticReport,
    TextDocumentRegistrationOptions,
    TextDocumentSyncOptions,
    ServerCapabilities,
    Diagnostic,
    DiagnosticRegistrationOptions,
    DocumentFilter,
    InitializeResult,
    DiagnosticRelatedInformation,
    Range,
    ##AnonymousType#230,
    WorkDoneProgressOptions,
    DiagnosticOptions