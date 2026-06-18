const TEXT_DOCUMENT_CONTENT_REGISTRATION_ID = "jetls-text-document-content"
const TEXT_DOCUMENT_CONTENT_REGISTRATION_METHOD = "workspace/textDocumentContent"

# Each `workspace/textDocumentContent` view gets its own scheme so document selectors
# can enable language features per view: TestRunner logs need none, while Julia-code
# views (macro expansion, type annotations, and future `code_typed`, …) can opt into
# semantic tokens, go-to-definition, etc. New views add their scheme here.
const TESTRUNNER_LOGS_SCHEME = "jetls-testrunner-logs"
const MACRO_EXPANSION_SCHEME = "jetls-macro-expansion"
const TYPE_ANNOTATION_SCHEME = "jetls-type-annotation"
const TEXT_DOCUMENT_CONTENT_SCHEMES = String[
    TESTRUNNER_LOGS_SCHEME,
    MACRO_EXPANSION_SCHEME,
    TYPE_ANNOTATION_SCHEME,
]

is_text_document_content_uri(uri::URI) = uri.scheme in TEXT_DOCUMENT_CONTENT_SCHEMES

struct TextDocumentContentRefreshCaller <: RequestCaller
    uri::URI
end

supports_text_document_content(server::Server) =
    getcapability(server, :workspace, :textDocumentContent) !== nothing

function text_document_content_options()
    return TextDocumentContentOptions(; schemes = TEXT_DOCUMENT_CONTENT_SCHEMES)
end

function text_document_content_registration()
    return Registration(;
        id = TEXT_DOCUMENT_CONTENT_REGISTRATION_ID,
        method = TEXT_DOCUMENT_CONTENT_REGISTRATION_METHOD,
        registerOptions = TextDocumentContentRegistrationOptions(;
            schemes = TEXT_DOCUMENT_CONTENT_SCHEMES))
end

# Decode the query parameters a view encodes into its content URI.
function parse_text_document_content_query(uri::URI)
    query = @something uri.query return Dict{String,String}()
    params = Dict{String,String}()
    for part in split(query, '&'; keepempty=false)
        key_value = split(part, '='; limit=2)
        length(key_value) == 2 || continue
        key = LSP.URIs2.unescapeuri(key_value[1])
        value = LSP.URIs2.unescapeuri(key_value[2])
        params[key] = value
    end
    return params
end

# Cached content (e.g. TestRunner logs)
# =====================================

function get_text_document_content(state::ServerState, uri::URI)
    entry = get(load(state.text_document_content_cache), uri, nothing)
    entry === nothing && return nothing
    return entry.text
end

function update_text_document_content!(server::Server, uri::URI, text::String)
    should_refresh = store!(server.state.text_document_content_cache) do data
        old_entry = get(data, uri, nothing)
        opened = old_entry !== nothing && old_entry.opened
        new_data = Base.PersistentDict(data, uri => TextDocumentContentEntry(text, opened))
        return new_data, opened
    end
    should_refresh && request_text_document_content_refresh!(server, uri)
    return nothing
end

function mark_text_document_content_opened!(server::Server, uri::URI)
    return store!(server.state.text_document_content_cache) do data
        entry = @something get(data, uri, nothing) return data, nothing
        new_data = Base.PersistentDict(data, uri => TextDocumentContentEntry(entry.text, true))
        return new_data, nothing
    end
end

function mark_text_document_content_closed!(server::Server, uri::URI)
    return store!(server.state.text_document_content_cache) do data
        entry = @something get(data, uri, nothing) return data, nothing
        new_data = Base.PersistentDict(data, uri => TextDocumentContentEntry(entry.text, false))
        return new_data, nothing
    end
end

function delete_text_document_content!(server::Server, uri::URI)
    return store!(server.state.text_document_content_cache) do data
        haskey(data, uri) || return data, nothing
        return Base.delete(data, uri), nothing
    end
end

function request_text_document_content_refresh!(server::Server, uri::URI)
    supports_text_document_content(server) || return nothing
    id = String(gensym(:TextDocumentContentRefreshRequest))
    addrequest!(server, id=>TextDocumentContentRefreshCaller(uri))
    params = TextDocumentContentRefreshParams(; uri)
    return send(server, TextDocumentContentRefreshRequest(; id, params))
end

# Request handlers
# ================

function handle_TextDocumentContentRequest(server::Server, msg::TextDocumentContentRequest)
    uri = msg.params.uri
    if !is_text_document_content_uri(uri)
        return send(server, TextDocumentContentResponse(; id = msg.id, result = null))
    end
    # Code views are computed on demand from the request URI rather than cached.
    if uri.scheme == MACRO_EXPANSION_SCHEME
        text = macro_expansion_text(server, uri)
        return send(server, TextDocumentContentResponse(;
            id = msg.id, result = TextDocumentContentResult(; text)))
    elseif uri.scheme == TYPE_ANNOTATION_SCHEME
        text = type_annotation_text(server, uri)
        return send(server, TextDocumentContentResponse(;
            id = msg.id, result = TextDocumentContentResult(; text)))
    end
    # Other schemes (e.g. TestRunner logs) are served from the content cache.
    text = @something get_text_document_content(server.state, uri) begin
        return send(server, TextDocumentContentResponse(; id = msg.id, result = null))
    end
    return send(server, TextDocumentContentResponse(;
        id = msg.id, result = TextDocumentContentResult(; text)))
end

function handle_text_document_content_refresh_response(
        server::Server, msg::Dict{Symbol,Any}, ::TextDocumentContentRefreshCaller
    )
    handle_response_error(server, msg, "refresh text document content")
    return nothing
end

# Opening content with graceful fallback
# ======================================
# Show a server-provided document, degrading by client capability: a
# `workspace/textDocumentContent` virtual document when supported, otherwise a
# temporary file opened via `window/showDocument`, otherwise a message pointing
# at that file. These views are read-only snapshots, so the temporary file is an
# equivalent fallback.

# Wraps a content thunk and pins its return type to `String`, keeping the
# abstract callback field out of call sites and the request caller. The thunk
# defers producing the content until a fallback needs it; the virtual-document
# path leaves it to the `textDocumentContent` handler to produce on demand.
struct ProduceText
    callback
end
(produce_text::ProduceText)() = produce_text.callback()::String

struct ShowTextDocumentContentCaller <: RequestCaller
    label::String
    uri::URI
    # For a virtual doc, `produce_text`/`tempfile_name` are set so a failed open
    # can retry as a temp file; for a temp file, `temp_path` is set so a failed
    # open can fall back to showing its path.
    produce_text::Union{Nothing,ProduceText}
    tempfile_name::Union{Nothing,String}
    temp_path::Union{Nothing,String}
end

# `label` is a noun phrase for fallback messages; `tempfile_name` is the
# basename of the temporary file.
function open_text_document_content!(
        server::Server, content_uri::Union{Nothing,URI},
        label::AbstractString, tempfile_name::AbstractString, produce_text::ProduceText;
        takeFocus::Bool=true
    )
    if (content_uri !== nothing && supports_text_document_content(server) &&
        supports(server, :window, :showDocument, :support))
        id = String(gensym(:ShowTextDocumentContentRequest))
        addrequest!(server, id => ShowTextDocumentContentCaller(
            label, content_uri, produce_text, tempfile_name, nothing))
        params = ShowDocumentParams(; uri = content_uri, takeFocus)
        return send(server, ShowDocumentRequest(; id, params))
    end
    return open_text_document_content_tempfile!(
        server, produce_text(), label, tempfile_name; takeFocus)
end

function open_text_document_content_tempfile!(
        server::Server, text::AbstractString,
        label::AbstractString, tempfile_name::AbstractString;
        takeFocus::Bool=true
    )
    saved = @something save_text_document_content_tempfile(
        server, text, label, tempfile_name) return nothing
    (; temp_path, uri) = saved
    if supports(server, :window, :showDocument, :support)
        id = String(gensym(:ShowTextDocumentContentRequest))
        addrequest!(server, id => ShowTextDocumentContentCaller(
            label, uri, nothing, nothing, temp_path))
        params = ShowDocumentParams(; uri, takeFocus)
        return send(server, ShowDocumentRequest(; id, params))
    end
    return show_text_document_content_path_message(server, label, temp_path, uri)
end

function save_text_document_content_tempfile(
        server::Server, text::AbstractString,
        label::AbstractString, tempfile_name::AbstractString
    )
    temp_path = joinpath(mktempdir(; cleanup=true), tempfile_name)
    try
        write(temp_path, text)
    catch err
        show_error_message(server, "Failed to save the $label: $(sprint(showerror, err))")
        return nothing
    end
    return (; temp_path, uri = filepath2uri(temp_path))
end

function show_text_document_content_path_message(
        server::Server, label::AbstractString, temp_path::AbstractString, uri::URI
    )
    return show_info_message(server, """
    Saved the $label temporarily to:

    [$temp_path]($uri)

    This file will be removed when JETLS exits.
    """)
end

function handle_show_text_document_content_response(
        server::Server, msg::Dict{Symbol,Any}, caller::ShowTextDocumentContentCaller
    )
    (; label, uri, produce_text, tempfile_name, temp_path) = caller
    if handle_response_error(server, msg, "show document")
    elseif haskey(msg, :result)
        result = msg[:result] # ::ShowDocumentResult
        if haskey(result, "success") && result["success"] === true
            return nothing
        else
            show_error_message(server, "Failed to open the $label")
        end
    else
        show_error_message(server, "Unexpected response from show document request")
    end
    # Recover: a failed virtual-document open retries as a temp file; a failed
    # temp-file open just points the user at the saved path.
    if temp_path !== nothing
        return show_text_document_content_path_message(server, label, temp_path, uri)
    elseif produce_text !== nothing && tempfile_name !== nothing
        return open_text_document_content_tempfile!(
            server, produce_text(), label, tempfile_name)
    end
    return nothing
end
