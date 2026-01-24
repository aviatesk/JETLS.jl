const CODE_LENS_REGISTRATION_ID = "jetls-code-lens"
const CODE_LENS_REGISTRATION_METHOD = "textDocument/codeLens"
const COMMAND_SHOW_REFERENCES = "jetls.showReferences"

function code_lens_options()
    return CodeLensOptions(;
        resolveProvider = true)
end

function code_lens_registration()
    return Registration(;
        id = CODE_LENS_REGISTRATION_ID,
        method = CODE_LENS_REGISTRATION_METHOD,
        registerOptions = CodeLensRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
            resolveProvider = true))
end

# For dynamic code lens registrations during development
# unregister(currently_running, Unregistration(;
#     id = CODE_LENS_REGISTRATION_ID,
#     method = CODE_LENS_REGISTRATION_METHOD))
# register(currently_running, code_lens_registration())

function handle_CodeLensRequest(server::Server, msg::CodeLensRequest, cancel_flag::CancelFlag)
    uri = msg.params.textDocument.uri
    result = get_file_info(server.state, uri, cancel_flag)
    if isnothing(result)
        return send(server, CodeLensResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, CodeLensResponse(; id = msg.id, result = nothing, error = result))
    end
    fi = result
    code_lenses = CodeLens[]
    testsetinfos = fi.testsetinfos
    if !isempty(testsetinfos) && get_config(server, :code_lens, :testrunner)
        testrunner_code_lenses!(code_lenses, uri, fi, testsetinfos)
    end
    if get_config(server, :code_lens, :references)
        references_code_lenses!(code_lenses, server.state, uri, fi)
    end
    return send(server,
        CodeLensResponse(;
            id = msg.id,
            result = @somereal code_lenses null))
end

const REFERENCES_CODE_LENS_SYMBOL_KINDS = (
    SymbolKind.Function,
    SymbolKind.Struct,
    SymbolKind.Constant,
    SymbolKind.Interface,
    SymbolKind.Class,
    SymbolKind.Module,
    SymbolKind.Enum,
)

function references_code_lenses!(
        code_lenses::Vector{CodeLens}, state::ServerState, uri::URI, fi::FileInfo
    )
    symbols = get_document_symbols!(state, uri, fi)
    isnothing(symbols) && return code_lenses
    collect_references_code_lenses!(code_lenses, uri, symbols)
    return code_lenses
end

function collect_references_code_lenses!(
        code_lenses::Vector{CodeLens}, uri::URI, symbols::Vector{DocumentSymbol}
    )
    for symbol in symbols
        if symbol.kind in REFERENCES_CODE_LENS_SYMBOL_KINDS
            occursin('.', symbol.name) && continue # Qualified defintions are not supported
            range = symbol.selectionRange
            data = ReferencesCodeLensData(uri, range.start.line, range.start.character)
            push!(code_lenses, CodeLens(; range, data))
        end
        children = symbol.children
        if children !== nothing
            collect_references_code_lenses!(code_lenses, uri, children)
        end
    end
    return nothing
end

function handle_CodeLensResolveRequest(
        server::Server, msg::CodeLensResolveRequest, cancel_flag::CancelFlag
    )
    code_lens = msg.params
    data = code_lens.data
    isa(data, ReferencesCodeLensData) ||
        return send(server, CodeLensResolveResponse(; id = msg.id, result = code_lens))

    pos = Position(; line = data.line, character = data.character)
    arguments = Any[string(data.uri), pos.line, pos.character]

    if !has_analyzed_context(server.state, data.uri)
        command = Command(;
            title = "? references",
            command = COMMAND_SHOW_REFERENCES,
            arguments)
        resolved = CodeLens(; range = code_lens.range, command, data = code_lens.data)
        return send(server, CodeLensResolveResponse(; id = msg.id, result = resolved))
    end

    result = get_file_info(server.state, data.uri, cancel_flag)
    if isnothing(result) || result isa ResponseError
        return send(server, CodeLensResolveResponse(; id = msg.id, result = code_lens))
    end

    fi = result
    locations = find_references(server, data.uri, fi, pos;
        include_declaration = false, cancel_flag)
    count = locations isa Vector ? length(locations) : 0

    title = count == 1 ? "1 reference" : "$count references"
    command = Command(; title, command = COMMAND_SHOW_REFERENCES, arguments)
    resolved = CodeLens(; range = code_lens.range, command, data = code_lens.data)
    return send(server,
        CodeLensResolveResponse(; id = msg.id, result = resolved))
end

struct CodeLensRefreshRequestCaller <: RequestCaller end

function request_codelens_refresh!(server::Server)
    supports(server, :workspace, :codeLens, :refreshSupport) || return nothing
    id = String(gensym(:CodeLensRefreshRequest))
    addrequest!(server, id=>CodeLensRefreshRequestCaller())
    return send(server, CodeLensRefreshRequest(; id, params = nothing))
end

function handle_code_lens_refresh_response(
        server::Server, msg::Dict{Symbol,Any}, ::CodeLensRefreshRequestCaller
    )
    if handle_response_error(server, msg, "refresh code lens")
    else
        # just valid request response cycle
    end
end
