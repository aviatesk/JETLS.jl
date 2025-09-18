const CODE_LENS_REGISTRATION_ID = "jetls-code-lens"
const CODE_LENS_REGISTRATION_METHOD = "textDocument/codeLens"

function code_lens_options()
    return CodeLensOptions(;
        resolveProvider = false)
end

function code_lens_registration()
    return Registration(;
        id = CODE_LENS_REGISTRATION_ID,
        method = CODE_LENS_REGISTRATION_METHOD,
        registerOptions = CodeLensRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
            resolveProvider = false))
end

# For dynamic code lens registrations during development
# unregister(currently_running, Unregistration(;
#     id = CODE_LENS_REGISTRATION_ID,
#     method = CODE_LENS_REGISTRATION_METHOD))
# register(currently_running, code_lens_registration())

function handle_CodeLensRequest(server::Server, msg::CodeLensRequest)
    uri = msg.params.textDocument.uri
    fi = @something get_file_info(server.state, uri) begin
        return send(server,
            CodeLensResponse(;
                id = msg.id,
                result = nothing,
                error = file_cache_error(uri)))
    end
    code_lenses = CodeLens[]
    testsetinfos = get_testsetinfos(server.state, uri)
    isnothing(testsetinfos) ||
        testrunner_code_lenses!(code_lenses, uri, fi, testsetinfos)
    entrypoints = get_entrypoints(server.state, uri)
    isnothing(entrypoints) ||
        report_trim_code_lens!(code_lenses, uri, fi, entrypoints)
    return send(server,
        CodeLensResponse(;
            id = msg.id,
            result = isempty(code_lenses) ? null : code_lenses))
end

struct CodeLensRefreshRequestCaller <: RequestCaller end

function request_codelens_refresh!(server::Server)
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
