include("URI.jl")
using .LSPURI

using JSON

@enum PositionEncoding UTF8 UTF16 UTF32
JSON.lower(x::PositionEncoding) = x == UTF8 ? "utf-8" : x == UTF16 ? "utf-16" : "utf-32"

# Define TextDocumentSyncKind as an enum
@enum TextDocumentSyncKind None Full Incremental
JSON.lower(x::TextDocumentSyncKind) = x == None ? 0 : x == Full ? 1 : 2

Base.@kwdef struct SaveOptions
    # /**
    #  * The client is supposed to include the content on save.
    #  */
    includeText::Union{Nothing,Bool} = nothing
end

# Define TextDocumentSyncOptions as a struct
Base.@kwdef struct TextDocumentSyncOptions
    # /**
    #  * Open and close notifications are sent to the server. If omitted open
    #  * close notification should not be sent.
    #  */
    openClose::Union{Nothing,Bool} = nothing
    # /**
    #  * Change notifications are sent to the server. See
    #  * TextDocumentSyncKind.None, TextDocumentSyncKind.Full and
    #  * TextDocumentSyncKind.Incremental. If omitted it defaults to
    #  * TextDocumentSyncKind.None.
    #  */
    change::Union{Nothing,TextDocumentSyncKind} = nothing
    # /**
    #  * If present will save notifications are sent to the server. If omitted
    #  * the notification should not be sent.
    #  */
    willSave::Union{Nothing,Bool} = nothing
    # /**
    #  * If present will save wait until requests are sent to the server. If
    #  * omitted the request should not be sent.
    #  */
    willSaveWaitUntil::Union{Nothing,Bool} = nothing
    # /**
    #  * If present save notifications are sent to the server. If omitted the
    #  * notification should not be sent.
    #  */
    save::Union{Nothing, Bool, SaveOptions} = nothing
end

# /**
#  * Diagnostic options.
#  *
#  * @since 3.17.0
#  */
Base.@kwdef struct DiagnosticOptions
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

Base.@kwdef struct ServerCapabilities
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
    positionEncoding::Union{Nothing,PositionEncoding} = nothing

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

Base.@kwdef struct InitializeResult
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
