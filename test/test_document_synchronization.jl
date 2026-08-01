module test_document_synchronization

include("setup.jl")

using Test
using JETLS
using JETLS.LSP
using JETLS.LSP.URIs2: filepath2uri

function registration_for_method(request::RegisterCapabilityRequest, method::String)
    return only(registration for registration in request.params.registrations
        if registration.method == method)
end

function test_config_document_sync_registration(
        request::RegisterCapabilityRequest, config_filter::Dict{String,Any}
    )
    for method in (
            "textDocument/didOpen",
            "textDocument/didChange",
            "textDocument/didClose"
        )
        reg = registration_for_method(request, method)
        options = reg.registerOptions::Dict{String,Any}
        @test config_filter in options["documentSelector"]
    end

    save_registration = registration_for_method(request, "textDocument/didSave")
    save_options = save_registration.registerOptions::Dict{String,Any}
    @test config_filter ∉ save_options["documentSelector"]
end

@testset "dynamic document synchronization registration" begin
    capabilities = ClientCapabilities(;
        textDocument = TextDocumentClientCapabilities(;
            synchronization = TextDocumentSyncClientCapabilities(;
                dynamicRegistration = true,
                didSave = true)),
        notebookDocument = NotebookDocumentClientCapabilities(;
            synchronization = NotebookDocumentSyncClientCapabilities(;
                dynamicRegistration = true)))
    withserver(; capabilities) do (;
            initialize_response,
            register_capability_request
        )
        server_capabilities = initialize_response.result.capabilities
        @test isnothing(server_capabilities.textDocumentSync)
        @test isnothing(server_capabilities.notebookDocumentSync)

        open_registration = registration_for_method(
            register_capability_request, "textDocument/didOpen")
        @test open_registration.id == "jetls-did-open-text-document"
        open_options = open_registration.registerOptions
        @test open_options isa TextDocumentRegistrationOptions
        open_filters = [
            (filter.language, filter.scheme, filter.pattern)
            for filter in open_options.documentSelector
        ]
        @test open_filters == [
            ("julia", "file", nothing),
            ("julia", "untitled", nothing),
            ("julia", "buffer", nothing),
        ]

        change_registration = registration_for_method(
            register_capability_request, "textDocument/didChange")
        @test change_registration.id == "jetls-did-change-text-document"
        change_options = change_registration.registerOptions
        @test change_options isa TextDocumentChangeRegistrationOptions
        @test change_options.syncKind == TextDocumentSyncKind.Full
        change_filters = [
            (filter.language, filter.scheme, filter.pattern)
            for filter in change_options.documentSelector
        ]
        @test change_filters == open_filters

        save_registration = registration_for_method(
            register_capability_request, "textDocument/didSave")
        @test save_registration.id == "jetls-did-save-text-document"
        save_options = save_registration.registerOptions
        @test save_options isa TextDocumentSaveRegistrationOptions
        @test save_options.includeText === true
        save_filters = [
            (filter.language, filter.scheme, filter.pattern)
            for filter in save_options.documentSelector
        ]
        @test save_filters == [("julia", "file", nothing)]

        close_registration = registration_for_method(
            register_capability_request, "textDocument/didClose")
        @test close_registration.id == "jetls-did-close-text-document"
        close_options = close_registration.registerOptions
        @test close_options isa TextDocumentRegistrationOptions
        close_filters = [
            (filter.language, filter.scheme, filter.pattern)
            for filter in close_options.documentSelector
        ]
        @test close_filters == open_filters

        notebook_registration = registration_for_method(
            register_capability_request, "notebookDocument/sync")
        @test notebook_registration.id == "jetls-notebook-document-sync"
        notebook_options = notebook_registration.registerOptions
        @test notebook_options isa NotebookDocumentSyncRegistrationOptions
        @test notebook_options.save === true
        @test length(notebook_options.notebookSelector) == 1
        notebook_selector = only(notebook_options.notebookSelector)
        @test notebook_selector.notebook == "jupyter-notebook"
        @test length(notebook_selector.cells) == 1
        @test only(notebook_selector.cells).language == "julia"
    end
end

@testset "static document synchronization fallback" begin
    capabilities = ClientCapabilities(;
        textDocument = TextDocumentClientCapabilities(;
            synchronization = TextDocumentSyncClientCapabilities(;
                dynamicRegistration = false,
                didSave = false)),
        notebookDocument = NotebookDocumentClientCapabilities(;
            synchronization = NotebookDocumentSyncClientCapabilities(;
                dynamicRegistration = false)))
    withserver(; capabilities) do (;
            initialize_response,
            register_capability_request
        )
        server_capabilities = initialize_response.result.capabilities
        text_options = server_capabilities.textDocumentSync
        @test text_options isa TextDocumentSyncOptions
        @test text_options.openClose === true
        @test text_options.change == TextDocumentSyncKind.Full
        @test isnothing(text_options.save)

        notebook_options = server_capabilities.notebookDocumentSync
        @test notebook_options isa NotebookDocumentSyncOptions
        @test notebook_options.save === true
        @test length(notebook_options.notebookSelector) == 1
        notebook_selector = only(notebook_options.notebookSelector)
        @test notebook_selector.notebook == "jupyter-notebook"
        @test length(notebook_selector.cells) == 1
        @test only(notebook_selector.cells).language == "julia"

        methods = Set(reg.method for reg in register_capability_request.params.registrations)
        @test isempty(intersect(methods, Set((
            "textDocument/didOpen",
            "textDocument/didChange",
            "textDocument/didSave",
            "textDocument/didClose",
            "notebookDocument/sync",
        ))))
    end
end

@testset "dynamic synchronization without didSave" begin
    capabilities = ClientCapabilities(;
        textDocument = TextDocumentClientCapabilities(;
            synchronization = TextDocumentSyncClientCapabilities(;
                dynamicRegistration = true,
                didSave = false)))
    withserver(; capabilities) do (;
            initialize_response,
            register_capability_request
        )
        @test isnothing(initialize_response.result.capabilities.textDocumentSync)

        methods = Set(reg.method for reg in register_capability_request.params.registrations)
        @test "textDocument/didOpen" in methods
        @test "textDocument/didChange" in methods
        @test "textDocument/didClose" in methods
        @test "textDocument/didSave" ∉ methods
    end
end

@testset "workspace config document synchronization registration" begin
    mktempdir() do dir
        root_uri = filepath2uri(dir)

        let capabilities = ClientCapabilities(;
                textDocument = TextDocumentClientCapabilities(;
                    filters = TextDocumentFilterClientCapabilities(;
                        relativePatternSupport = true),
                    synchronization = TextDocumentSyncClientCapabilities(;
                        dynamicRegistration = true,
                        didSave = true)))
            withserver(; capabilities, rootUri = root_uri) do (;
                    register_capability_json_request
                )
                config_filter = Dict{String,Any}(
                    "scheme" => "file",
                    "pattern" => Dict{String,Any}(
                        "baseUri" => string(root_uri),
                        "pattern" => JETLS.CONFIG_FILE))
                test_config_document_sync_registration(
                    register_capability_json_request, config_filter)
            end
        end

        let capabilities = ClientCapabilities(;
                textDocument = TextDocumentClientCapabilities(;
                    synchronization = TextDocumentSyncClientCapabilities(;
                        dynamicRegistration = true,
                        didSave = true)))
            withserver(; capabilities, rootUri = root_uri) do (;
                    register_capability_json_request
                )
                config_filter = Dict{String,Any}(
                    "scheme" => "file",
                    "pattern" => JETLS.CONFIG_FILE_GLOB_PATTERN)
                test_config_document_sync_registration(
                    register_capability_json_request, config_filter)
            end
        end
    end
end

@testset "unsupported text documents are ignored" begin
    mktempdir() do dir
        server = JETLS.Server()
        state = server.state
        state.root_path = dir
        uri = filepath2uri(joinpath(dir, "Manifest.toml"))

        open_notification = DidOpenTextDocumentNotification(;
            params = DidOpenTextDocumentParams(;
                textDocument = TextDocumentItem(;
                    uri, languageId="toml", version=1, text="[deps]\n")))
        @test JETLS.handle_DidOpenTextDocumentNotification(server, open_notification) === nothing
        @test !JETLS.is_synchronized(state, uri)
        @test !haskey(JETLS.load(state.saved_file_cache), uri)
        @test JETLS.is_rejected_text_document(state, uri)
        @test !JETLS.may_have_file_info(state, uri)

        config_uri = filepath2uri(joinpath(dir, JETLS.CONFIG_FILE))
        @test !JETLS.may_have_file_info(state, config_uri)

        nested_config_uri = filepath2uri(joinpath(dir, "nested", JETLS.CONFIG_FILE))
        nested_open = make_DidOpenTextDocumentNotification(nested_config_uri, ""; languageId = "toml")
        JETLS.handle_DidOpenTextDocumentNotification(server, nested_open)
        @test JETLS.get_config_document(state, nested_config_uri) === nothing
        @test JETLS.is_rejected_text_document(state, nested_config_uri)

        change_notification = DidChangeTextDocumentNotification(;
            params = DidChangeTextDocumentParams(;
                textDocument = VersionedTextDocumentIdentifier(; uri, version=2),
                contentChanges = TextDocumentContentChangeEvent[
                    TextDocumentContentChangeEvent(; text="[compat]\n")]))
        @test JETLS.handle_DidChangeTextDocumentNotification(server, change_notification) === nothing
        @test !JETLS.is_synchronized(state, uri)

        save_notification = DidSaveTextDocumentNotification(;
            params = DidSaveTextDocumentParams(;
                textDocument = TextDocumentIdentifier(; uri), text="[compat]\n"))
        @test JETLS.handle_DidSaveTextDocumentNotification(server, save_notification) === nothing
        @test !haskey(JETLS.load(state.saved_file_cache), uri)

        delayed_uri = filepath2uri(joinpath(dir, "Project.toml"))
        waiter = Threads.@spawn JETLS.get_file_info(
            state, delayed_uri, JETLS.CancelFlag(false); timeout=5.0)
        @test timedwait(() -> istaskstarted(waiter), 1.0) == :ok
        sleep(0.1)
        @test !istaskdone(waiter)
        delayed_open = DidOpenTextDocumentNotification(;
            params = DidOpenTextDocumentParams(;
                textDocument = TextDocumentItem(;
                    uri = delayed_uri,
                    languageId = "toml",
                    version = 1,
                    text = "[deps]\n")))
        JETLS.handle_DidOpenTextDocumentNotification(server, delayed_open)
        @test timedwait(() -> istaskdone(waiter), 1.0) == :ok
        @test istaskdone(waiter) && fetch(waiter) === nothing

        close_notification = DidCloseTextDocumentNotification(;
            params = DidCloseTextDocumentParams(;
                textDocument = TextDocumentIdentifier(; uri)))
        @test JETLS.handle_DidCloseTextDocumentNotification(server, close_notification) === nothing
        @test !JETLS.is_synchronized(state, uri)
        @test !JETLS.is_rejected_text_document(state, uri)
    end
end

end # module test_document_synchronization
