const TEXT_DOCUMENT_CONTENT_REGISTRATION_ID = "jetls-text-document-content"
const TEXT_DOCUMENT_CONTENT_REGISTRATION_METHOD = "workspace/textDocumentContent"
const TEXT_DOCUMENT_CONTENT_SCHEME = "jetls"

struct TextDocumentContentRefreshCaller <: RequestCaller
    uri::URI
end

supports_text_document_content(server::Server) =
    getcapability(server, :workspace, :textDocumentContent) !== nothing

function text_document_content_options()
    return TextDocumentContentOptions(; schemes = String[TEXT_DOCUMENT_CONTENT_SCHEME])
end

function text_document_content_registration()
    return Registration(;
        id = TEXT_DOCUMENT_CONTENT_REGISTRATION_ID,
        method = TEXT_DOCUMENT_CONTENT_REGISTRATION_METHOD,
        registerOptions = TextDocumentContentRegistrationOptions(;
            schemes = String[TEXT_DOCUMENT_CONTENT_SCHEME]))
end

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
    return send(server, TextDocumentContentRefreshRequest(;
        id,
        params = TextDocumentContentRefreshParams(; uri)))
end

function handle_TextDocumentContentRequest(server::Server, msg::TextDocumentContentRequest)
    uri = msg.params.uri
    if uri.scheme != TEXT_DOCUMENT_CONTENT_SCHEME
        return send(server, TextDocumentContentResponse(; id = msg.id, result = null))
    end
    text = get_text_document_content(server.state, uri)
    text === nothing && return send(server, TextDocumentContentResponse(;
        id = msg.id,
        result = null))
    return send(server, TextDocumentContentResponse(;
        id = msg.id,
        result = TextDocumentContentResult(; text)))
end

function handle_text_document_content_refresh_response(
        server::Server, msg::Dict{Symbol,Any}, ::TextDocumentContentRefreshCaller
    )
    handle_response_error(server, msg, "refresh text document content")
    return nothing
end
