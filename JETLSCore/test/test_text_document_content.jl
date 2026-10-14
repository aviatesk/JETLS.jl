module test_text_document_content

include("setup.jl")

using Test
using JETLS
using JETLS.LSP
using JETLS.LSP.URIs2

function registration_for_method(request::RegisterCapabilityRequest, method::String)
    return only(registration for registration in request.params.registrations
        if registration.method == method)
end

@testset "virtual document synchronization registration" begin
    capabilities = ClientCapabilities(;
        workspace = WorkspaceClientCapabilities(;
            textDocumentContent = TextDocumentContentClientCapabilities(;
                dynamicRegistration = true)),
        textDocument = TextDocumentClientCapabilities(;
            synchronization = TextDocumentSyncClientCapabilities(;
                dynamicRegistration = true,
                didSave = true)))
    withserver(; capabilities) do (; register_capability_request)
        virtual_schemes = [
            "jetls-testrunner-logs",
            "jetls-macro-expansion",
            "jetls-type-annotation",
        ]

        content_registration = registration_for_method(
            register_capability_request, "workspace/textDocumentContent")
        @test content_registration.id == "jetls-text-document-content"
        content_options = content_registration.registerOptions
        @test content_options isa TextDocumentContentRegistrationOptions
        @test content_options.schemes == virtual_schemes

        for method in ("textDocument/didOpen", "textDocument/didClose")
            registration = registration_for_method(register_capability_request, method)
            options = registration.registerOptions
            registered_schemes = Set(filter.scheme for filter in options.documentSelector
                if isnothing(filter.language))
            @test registered_schemes == Set(virtual_schemes)
        end

        for method in ("textDocument/didChange", "textDocument/didSave")
            registration = registration_for_method(register_capability_request, method)
            options = registration.registerOptions
            registered_schemes = Set(filter.scheme for filter in options.documentSelector)
            @test isempty(intersect(registered_schemes, Set(virtual_schemes)))
        end
    end
end

@testset "static virtual document content registration" begin
    capabilities = ClientCapabilities(;
        workspace = WorkspaceClientCapabilities(;
            textDocumentContent = TextDocumentContentClientCapabilities(;
                dynamicRegistration = false)),
        textDocument = TextDocumentClientCapabilities(;
            synchronization = TextDocumentSyncClientCapabilities(;
                dynamicRegistration = true,
                didSave = true)))
    withserver(; capabilities) do (;
            initialize_response,
            register_capability_request
        )
        virtual_schemes = [
            "jetls-testrunner-logs",
            "jetls-macro-expansion",
            "jetls-type-annotation",
        ]

        server_capabilities = initialize_response.result.capabilities
        @test isnothing(server_capabilities.textDocumentSync)
        workspace_options = server_capabilities.workspace
        @test workspace_options isa WorkspaceOptions
        content_options = workspace_options.textDocumentContent
        @test content_options isa TextDocumentContentOptions
        @test content_options.schemes == virtual_schemes

        methods = Set(reg.method for reg in register_capability_request.params.registrations)
        @test "workspace/textDocumentContent" ∉ methods
        for method in ("textDocument/didOpen", "textDocument/didClose")
            registration = registration_for_method(register_capability_request, method)
            options = registration.registerOptions
            registered_schemes = Set(filter.scheme for filter in options.documentSelector
                if isnothing(filter.language))
            @test registered_schemes == Set(virtual_schemes)
        end
    end
end

@testset "virtual document open and close handling" begin
    # Virtual documents use the text synchronization protocol only to track whether
    # they are open. They must not enter the Julia analysis path or its file cache.
    server = JETLS.Server()
    uri = URI(;
        scheme = JETLS.TESTRUNNER_LOGS_SCHEME,
        path = "/testrunner/logs",
        query = "source=x&index=1&name=ts")
    JETLS.update_text_document_content!(server, uri, "logs\n")

    open_msg = DidOpenTextDocumentNotification(;
        params = DidOpenTextDocumentParams(;
            textDocument = TextDocumentItem(;
                uri, languageId = "log", version = 1, text = "logs\n")))
    @test JETLS.handle_DidOpenTextDocumentNotification(server, open_msg) === nothing
    @test JETLS.get_file_info(server.state, uri) === nothing
    @test JETLS.load(server.state.text_document_content_cache)[uri].opened

    close_msg = DidCloseTextDocumentNotification(;
        params = DidCloseTextDocumentParams(;
            textDocument = TextDocumentIdentifier(; uri)))
    @test JETLS.handle_DidCloseTextDocumentNotification(server, close_msg) === nothing
    @test !JETLS.load(server.state.text_document_content_cache)[uri].opened
end

@testset "parse_text_document_content_query" begin
    # a URI with no query yields no parameters
    let uri = URI(; scheme = "jetls-x", path = "/p")
        @test isempty(JETLS.parse_text_document_content_query(uri))
    end

    # multiple `&`-separated parameters are decoded
    let uri = URI(; scheme = "jetls-x", path = "/p", query = "a=1&b=two")
        params = JETLS.parse_text_document_content_query(uri)
        @test params["a"] == "1"
        @test params["b"] == "two"
    end

    # percent-escaped values round-trip (e.g. a source URI stored as a value)
    let value = "file:///tmp/a b.jl?x=1",
        uri = URI(; scheme = "jetls-x", path = "/p",
                    query = "source=$(URIs2.escapeuri(value))")
        params = JETLS.parse_text_document_content_query(uri)
        @test params["source"] == value
    end

    # only the first `=` splits key/value, and parts without `=` are skipped
    let uri = URI(; scheme = "jetls-x", path = "/p", query = "k=a=b&bogus&c=3")
        params = JETLS.parse_text_document_content_query(uri)
        @test params["k"] == "a=b"
        @test params["c"] == "3"
        @test !haskey(params, "bogus")
    end
end

@testset "save_text_document_content_tempfile" begin
    server = JETLS.Server()
    saved = JETLS.save_text_document_content_tempfile(server, "hello\nworld\n",
        #=label=# "thing", #=tempfile_name=# "x.jl")
    @test saved !== nothing
    @test basename(saved.temp_path) == "x.jl"
    @test read(saved.temp_path, String) == "hello\nworld\n"
    @test JETLS.filepath2uri(saved.temp_path) == saved.uri
end

end # module test_text_document_content
