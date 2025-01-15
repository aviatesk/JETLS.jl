include("URI.jl")
using .LSPURI

include("macro.jl")

const LSPAny = Any

const DocumentUri = String;
const URI = String;

# /**
#  * A set of predefined position encoding kinds.
#  *
#  * @since 3.17.0
#  */
@namespace PositionEncodingKind begin
    # /**
    #  * Character offsets count UTF-8 code units (e.g bytes).
    #  */
    UTF8 = "utf-8";

    # /**
    #  * Character offsets count UTF-16 code units.
    #  *
    #  * This is the default and must always be supported
    #  * by servers
    #  */
    UTF16 = "utf-16";

    # /**
    #  * Character offsets count UTF-32 code units.
    #  *
    #  * Implementation note: these are the same as Unicode code points,
    #  * so this `PositionEncodingKind` may also be used for an
    #  * encoding-agnostic representation of character offsets.
    #  */
    UTF32 = "utf-32";
end

# /**
#  * Defines how the host (editor) should sync document changes to the language
#  * server.
#  */
@namespace TextDocumentSyncKind begin
    # /**
    #  * Documents should not be synced at all.
    #  */
    None = 0;

    # /**
    #  * Documents are synced by always sending the full content
    #  * of the document.
    #  */
    Full = 1;

    # /**
    #  * Documents are synced by sending the full content on open.
    #  * After that only incremental updates to the document are
    #  * sent.
    #  */
    Incremental = 2;
end

@tsdef struct SaveOptions
    # /**
    #  * The client is supposed to include the content on save.
    #  */
    includeText::Union{Nothing,Bool} = nothing;
end

# Define TextDocumentSyncOptions as a struct
@tsdef struct TextDocumentSyncOptions
    # /**
    #  * Open and close notifications are sent to the server. If omitted open
    #  * close notification should not be sent.
    #  */
    openClose::Union{Nothing,Bool} = nothing;
    # /**
    #  * Change notifications are sent to the server. See
    #  * TextDocumentSyncKind.None, TextDocumentSyncKind.Full and
    #  * TextDocumentSyncKind.Incremental. If omitted it defaults to
    #  * TextDocumentSyncKind.None.
    #  */
    change::Union{Nothing,TextDocumentSyncKind} = nothing;
    # /**
    #  * If present will save notifications are sent to the server. If omitted
    #  * the notification should not be sent.
    #  */
    willSave::Union{Nothing,Bool} = nothing;
    # /**
    #  * If present will save wait until requests are sent to the server. If
    #  * omitted the request should not be sent.
    #  */
    willSaveWaitUntil::Union{Nothing,Bool} = nothing;
    # /**
    #  * If present save notifications are sent to the server. If omitted the
    #  * notification should not be sent.
    #  */
    save::Union{Nothing, Bool, SaveOptions} = nothing;
end

# /**
#  * Diagnostic options.
#  *
#  * @since 3.17.0
#  */
@tsdef struct DiagnosticOptions
    # /**
    #  * An optional identifier under which the diagnostics are
    #  * managed by the client.
    #  */
    identifier::Union{Nothing,String};

    # /**
    #  * Whether the language has inter file dependencies meaning that
    #  * editing code in one file can result in a different diagnostic
    #  * set in another file. Inter file dependencies are common for
    #  * most programming languages and typically uncommon for linters.
    #  */
    interFileDependencies::Bool = nothing

    # /**
    #  * The server provides support for workspace diagnostics as well.
    #  */
    workspaceDiagnostics::Bool
end

@tsdef struct ServerCapabilities
    # /**
    #  * The position encoding the server picked from the encodings offered
    #  * by the client via the client capability `general.positionEncodings`.
    #  *
    #  * If the client didn't provide any position encodings the only valid
    #  * value that a server can return is 'utf-16'.
    #  *
    #  * If omitted it defaults to 'utf-16'.
    #  *
    #  * @since 3.17.0
    #  */
    positionEncoding::Union{Nothing,PositionEncodingKind} = nothing

    # /**
    #  * Defines how text documents are synced. Is either a detailed structure
    #  * defining each notification or for backwards compatibility the
    #  * TextDocumentSyncKind number. If omitted it defaults to
    #  * `TextDocumentSyncKind.None`.
    #  */
    textDocumentSync::Union{Nothing,TextDocumentSyncOptions,TextDocumentSyncKind} = nothing

    # /**
    #  * The server has support for pull model diagnostics.
    #  *
    #  * @since 3.17.0
    #  */
    diagnosticProvider::Union{Nothing,DiagnosticOptions,#=DiagnosticRegistrationOptions=#} = nothing
end

@tsdef struct InitializeResult
    # /**
    #  * The capabilities the language server provides.
    #  */
    capabilities::ServerCapabilities

    # /**
    #  * Information about the server.
    #  *
    #  * @since 3.15.0
    #  */
    serverInfo::@NamedTuple{
        # /**
        #  * The name of the server as defined by the server.
        #  */
        name::String,

        # /**
        #  * The server's version as defined by the server.
        #  */
        version::Union{Nothing,String}
    };
end

# /**
#  * The document diagnostic report kinds.
#  *
#  * @since 3.17.0
#  */
@namespace DocumentDiagnosticReportKind begin
    # /**
    #  * A diagnostic report with a full
    #  * set of problems.
    #  */
    Full = "full";

    # /**
    #  * A report indicating that the last
    #  * returned report is still accurate.
    #  */
    Unchanged = "unchanged";
end

"""
Position in a text document expressed as zero-based line and zero-based character offset.
A position is between two characters like an ‘insert’ cursor in an editor.
Special values like for example -1 to denote the end of a line are not supported.
"""
@tsdef struct Position
	"""/**
	 * Line position in a document (zero-based).
	 */"""
	line::UInt;

	"""/**
	 * Character offset on a line in a document (zero-based). The meaning of this
	 * offset is determined by the negotiated `PositionEncodingKind`.
	 *
	 * If the character value is greater than the line length it defaults back
	 * to the line length.
	 */"""
	character::UInt;
end

"""
A range in a text document expressed as (zero-based) start and end positions.
A range is comparable to a selection in an editor. Therefore, the end position is exclusive.
If you want to specify a range that contains a line including the line ending character(s)
then use an end position denoting the start of the next line. For example:
```js
{
    start: { line: 5, character: 23 },
    end : { line: 6, character: 0 }
}
```
"""
@tsdef struct Range
	"""/**
	 * The range's start position.
	 */"""
	start::Position;

	"""/**
	 * The range's end position.
	 */"""
    var"end"::Position;
end

@namespace DiagnosticSeverity begin
	"""/**
	 * Reports an error.
	 */"""
	Error = 1;
	"""/**
	 * Reports a warning.
	 */"""
	Warning = 2;
	"""/**
	 * Reports an information.
	 */"""
	Information = 3;
	"""/**
	 * Reports a hint.
	 */"""
	Hint = 4;
end

"""/**
 * Structure to capture a description for an error code.
 *
 * @since 3.16.0
 */"""
@tsdef struct CodeDescription
	"""/**
	 * An URI to open with more information about the diagnostic error.
	 */"""
	href :: URI;
end

"""/**
 * The diagnostic tags.
 *
 * @since 3.15.0
 */"""
@namespace DiagnosticTag begin
	"""/**
	 * Unused or unnecessary code.
	 *
	 * Clients are allowed to render diagnostics with this tag faded out
	 * instead of having an error squiggle.
	 */"""
	Unnecessary = 1;
	"""/**
	 * Deprecated or obsolete code.
	 *
	 * Clients are allowed to rendered diagnostics with this tag strike through.
	 */"""
	Deprecated = 2;
end

"""
Represents a location inside a resource, such as a line inside a text file.
"""
@tsdef struct Location
	uri :: DocumentUri;
	range :: Range;
end

"""/**
 * Represents a related message and source code location for a diagnostic.
 * This should be used to point to code locations that cause or are related to
 * a diagnostics, e.g when duplicating a symbol in a scope.
 */"""
@tsdef struct DiagnosticRelatedInformation
	"""/**
	 * The location of this related diagnostic information.
	 */"""
	location :: Location;

	"""/**
	 * The message of this related diagnostic information.
	 */"""
	message :: String;
end

"""
Represents a diagnostic, such as a compiler error or warning.
Diagnostic objects are only valid in the scope of a resource.
"""
@tsdef struct Diagnostic
	"""/**
	 * The range at which the message applies.
	 */"""
	range :: Range;

    """/**
	 * The diagnostic's severity. To avoid interpretation mismatches when a
	 * server is used with different clients it is highly recommended that
	 * servers always provide a severity value. If omitted, it’s recommended
	 * for the client to interpret it as an Error severity.
	 */"""
	severity :: Union{Nothing, DiagnosticSeverity} = nothing;

    """/**
	 * The diagnostic's code, which might appear in the user interface.
	 */"""
	code :: Union{Nothing, Int, String};

    """/**
	 * An optional property to describe the error code.
	 *
	 * @since 3.16.0
	 */"""
	codeDescription :: Union{Nothing, CodeDescription} = nothing;

    """/**
	 * A human-readable string describing the source of this
	 * diagnostic, e.g. 'typescript' or 'super lint'.
	 */"""
	source :: String;

    """/**
	 * The diagnostic's message.
	 */"""
	message :: String;

    """/**
	 * Additional metadata about the diagnostic.
	 *
	 * @since 3.15.0
	 */"""
	tags :: Union{Nothing, Vector{DiagnosticTag}} = nothing;

    """/**
	 * An array of related diagnostic information, e.g. when symbol-names within
	 * a scope collide all definitions can be marked via this property.
	 */"""
	relatedInformation :: Union{Nothing, Vector{DiagnosticRelatedInformation}} = nothing;

	"""/**
	 * A data entry field that is preserved between a
	 * `textDocument/publishDiagnostics` notification and
	 * `textDocument/codeAction` request.
	 *
	 * @since 3.16.0
	 */"""
	data :: Union{Nothing, LSPAny} = nothing;
end

# /**
#  * A diagnostic report with a full set of problems.
#  *
#  * @since 3.17.0
#  */
@tsdef struct FullDocumentDiagnosticReport
    # /**
    #  * A full document diagnostic report.
    #  */
    kind::DocumentDiagnosticReportKind;

    # /**
    #  * An optional result id. If provided it will
    #  * be sent on the next diagnostic request for the
    #  * same document.
    #  */
    resultId::Union{Nothing,String} = nothing;

    # /**
    #  * The actual items.
    #  */
    items::Vector{Diagnostic};
end

# /**
#  * A full document diagnostic report for a workspace diagnostic result.
#  *
#  * @since 3.17.0
#  */
@tsdef struct WorkspaceFullDocumentDiagnosticReport @extends FullDocumentDiagnosticReport
    # /**
    #  * The URI for which diagnostic information is reported.
    #  */
    uri::DocumentUri

    # /**
    #  * The version number for which the diagnostics are reported.
    #  * If the document is not marked as open `null` can be provided.
    #  */
    version::Union{Nothing,Int} = nothing
end

"""/**
 * A workspace diagnostic report.
 *
 * @since 3.17.0
 */"""
@tsdef struct WorkspaceDiagnosticReport
    items::Vector{WorkspaceFullDocumentDiagnosticReport};
end
