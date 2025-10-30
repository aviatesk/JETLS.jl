"""
Receives `msg::InitializeRequest` and sets up the `server.state` based on `msg.params`.
As a response to this `msg`, it returns an `InitializeResponse` and performs registration of
server capabilities and server information that should occur during initialization.

For server capabilities, it's preferable to register those that support dynamic/static
registration in the `handle_InitializedNotification` handler using `RegisterCapabilityRequest`.
On the other hand, basic server capabilities such as `textDocumentSync` must be registered here,
and features that don't extend and support `StaticRegistrationOptions` like "completion"
need to be registered in this handler in a case when the client does not support
dynamic registration.
"""
function handle_InitializeRequest(
        server::Server, msg::InitializeRequest;
        client_process_id::Union{Int,Nothing} = nothing
    )
    state = server.state
    init_params = state.init_params = msg.params

    workspaceFolders = init_params.workspaceFolders
    if workspaceFolders !== nothing
        state.workspaceFolders = URI[uri for (; uri) in workspaceFolders]
    else
        rootUri = init_params.rootUri
        state.workspaceFolders = URI[]
        if rootUri !== nothing
            push!(state.workspaceFolders, rootUri)
        else
            @warn "No workspaceFolders or rootUri in InitializeRequest - some functionality will be limited"
        end
    end

    # Update root information
    if isempty(state.workspaceFolders)
        # leave Refs undefined
    elseif length(state.workspaceFolders) == 1
        root_uri = only(state.workspaceFolders)
        root_path = uri2filepath(root_uri)
        if root_path !== nothing
            state.root_path = root_path
            env_path = find_env_path(root_path)
            if env_path !== nothing
                state.root_env_path = env_path
            end
        else
            @warn "Root URI scheme not supported for workspace analysis" root_uri
        end
    else
        @warn "Multiple workspaceFolders are not supported - using limited functionality" state.workspaceFolders
        # leave Refs undefined
    end

    if !isdefined(state, :root_path)
        if JETLS_DEV_MODE
            @info "`server.state.root_path` is not defined, skip config registration at startup."
        end
    else
        config_path = joinpath(state.root_path, ".JETLSConfig.toml")
        if isfile(config_path)
            load_file_config!(Returns(nothing), server, config_path)
        end
    end

    fix_static_settings!(state.config_manager)

    start_analysis_workers!(server)

    if supports(server, :textDocument, :completion, :dynamicRegistration)
        completionProvider = nothing # will be registered dynamically
    else
        completionProvider = completion_options()
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/completion' with `InitializeResponse`"
        end
    end

    if supports(server, :textDocument, :signatureHelp, :dynamicRegistration)
        signatureHelpProvider = nothing # will be registered dynamically
    else
        signatureHelpProvider = signature_help_options()
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/signatureHelp' with `InitializeResponse`"
        end
    end

    if supports(server, :textDocument, :definition, :dynamicRegistration)
        definitionProvider = nothing # will be registered dynamically
    else
        definitionProvider = definition_options()
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/definition' with `InitializeResponse`"
        end
    end

    if supports(server, :textDocument, :documentHighlight, :dynamicRegistration)
        documentHighlightProvider = nothing # will be registered dynamically
    else
        documentHighlightProvider = document_highlight_options()
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/documentHighlight' with `InitializeResponse`"
        end
    end

    if supports(server, :textDocument, :hover, :dynamicRegistration)
        hoverProvider = nothing # will be registered dynamically
    else
        hoverProvider = hover_options()
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/hover' with `InitializeResponse`"
        end
    end

    if supports(server, :textDocument, :diagnostic, :dynamicRegistration)
        diagnosticProvider = nothing # will be registered dynamically
    else
        diagnosticProvider = diagnostic_options()
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/diagnostic' with `InitializeResponse`"
        end
    end

    if supports(server, :textDocument, :codeLens, :dynamicRegistration)
        codeLensProvider = nothing # will be registered dynamically
    else
        codeLensProvider = code_lens_options()
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/codeLens' with `InitializeResponse`"
        end
    end

    if supports(server, :textDocument, :codeAction, :dynamicRegistration)
        codeActionProvider = nothing # will be registered dynamically
    else
        codeActionProvider = code_action_options()
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/codeAction' with `InitializeResponse`"
        end
    end

    # No support for dynamic registration
    executeCommandProvider = execute_command_options()
    if JETLS_DEV_MODE
        @info "Registering 'workspace/executeCommand' with `InitializeResponse`"
    end

    if supports(server, :textDocument, :formatting, :dynamicRegistration)
        documentFormattingProvider = nothing # will be registered dynamically
    else
        documentFormattingProvider = formatting_options(server)
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/formatting' with `InitializeResponse`"
        end
    end

    if supports(server, :textDocument, :rangeFormatting, :dynamicRegistration)
        documentRangeFormattingProvider = nothing # will be registered dynamically
    else
        documentRangeFormattingProvider = range_formatting_options(server)
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/rangeFormatting' with `InitializeResponse`"
        end
    end

    # if getcapability(server,
    #     :textDocument, :inlayHint, :dynamicRegistration) isa Bool
    #     inlayHintProvider = nothing # will be registered dynamically (static registration not supported)
    # NOTE Although `InlayHintRegistrationOptions` extends `StaticRegistrationOptions`
    # and ideally we would want to perform static registration, it seems that some
    # clients do not support static registration during `InitializedNotification` properly,
    # so we are forced to register here instead
    if supports(server, :textDocument, :inlayHint, :dynamicRegistration)
        inlayHintProvider = nothing # will be registered dynamically
    else
        inlayHintProvider = inlay_hint_options()
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/inlayHint' with `InitializeResponse`"
        end
    end

    if supports(server, :textDocument, :rename, :dynamicRegistration)
        renameProvider = nothing # will be registered dynamically
    else
        renameProvider = rename_options()
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/rename' with `InitializeResponse`"
        end
    end

    positionEncodings = getcapability(state, :general, :positionEncodings)
    if isnothing(positionEncodings) || isempty(positionEncodings)
        positionEncoding = PositionEncodingKind.UTF16
    elseif PositionEncodingKind.UTF8 in positionEncodings
        positionEncoding = PositionEncodingKind.UTF8
    else
        positionEncoding = first(positionEncodings)
    end
    state.encoding = positionEncoding

    result = InitializeResult(;
        capabilities = ServerCapabilities(;
            positionEncoding,
            textDocumentSync = TextDocumentSyncOptions(;
                openClose = true,
                change = TextDocumentSyncKind.Full,
                save = SaveOptions(;
                    includeText = true)),
            completionProvider,
            signatureHelpProvider,
            definitionProvider,
            documentHighlightProvider,
            hoverProvider,
            diagnosticProvider,
            codeActionProvider,
            codeLensProvider,
            documentFormattingProvider,
            documentRangeFormattingProvider,
            executeCommandProvider,
            inlayHintProvider,
            renameProvider,
        ),
        serverInfo = (;
            name = "JETLS",
            version = "0.0.0"))

    process_id = init_params.processId
    if !isnothing(process_id)
        if client_process_id !== nothing
            if client_process_id != process_id
                @warn "Different client process IDs given" client_process_id process_id
            else
                @goto skip_monitoring
            end
        end
        JETLS_DEV_MODE && @info "Monitoring parent process ID" process_id
        Threads.@spawn while true
            # To handle cases where the client crashes and cannot execute the normal
            # server shutdown process, check every 60 seconds whether the `processId`
            # is alive, and if not, put a special message token `SelfShutdownNotification`
            # into the `endpoint` queue. See `runserver(server::Server)`.
            sleep(60)
            isopen(server.endpoint) || break
            if !iszero(@ccall uv_kill(process_id::Cint, 0::Cint)::Cint)
                put!(server.endpoint.in_msg_queue, self_shutdown_token)
                break
            end
        end
    elseif client_process_id === nothing
        @warn "No client process ID provided, zombie processes may occur if the client terminates abnormally"
    else
        # Monitoring for this client process is already being performed within `runserver`, so it can be skipped
        @label skip_monitoring
    end

    return send(server,
        InitializeResponse(;
            id = msg.id,
            result))
end

"""
Handler that performs the necessary actions when receiving an `InitializedNotification`.
Primarily, it registers LSP features that support dynamic/static registration and
should be enabled by default.
"""
function handle_InitializedNotification(server::Server)
    state = server.state

    isdefined(state, :init_params) || error("Initialization process not completed") # to exit the server loop

    registrations = Registration[]

    if supports(server, :textDocument, :completion, :dynamicRegistration)
        push!(registrations, completion_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/completion' upon `InitializedNotification`"
        end
    else
        # NOTE If completion's `dynamicRegistration` is not supported,
        # it needs to be registered along with initialization in the `InitializeResponse`,
        # since `CompletionRegistrationOptions` does not extend `StaticRegistrationOptions`.
    end

    if supports(server, :textDocument, :signatureHelp, :dynamicRegistration)
        push!(registrations, signature_help_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/signatureHelp' upon `InitializedNotification`"
        end
    else
        # NOTE If completion's `dynamicRegistration` is not supported,
        # it needs to be registered along with initialization in the `InitializeResponse`,
        # since `SignatureHelpRegistrationOptions` does not extend `StaticRegistrationOptions`.
    end

    if supports(server, :textDocument, :definition, :dynamicRegistration)
        push!(registrations, definition_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/definition' upon `InitializedNotification`"
        end
    else
        # NOTE If definition's `dynamicRegistration` is not supported,
        # it needs to be registered along with initialization in the `InitializeResponse`,
        # since `DefinitionRegistrationOptions` does not extend `StaticRegistrationOptions`.
    end

    if supports(server, :textDocument, :documentHighlight, :dynamicRegistration)
        push!(registrations, document_highlight_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/documentHighlight' upon `InitializedNotification`"
        end
    else
        # NOTE If documentHighlight's `dynamicRegistration` is not supported,
        # it needs to be registered along with initialization in the `InitializeResponse`.
    end

    if supports(server, :textDocument, :hover, :dynamicRegistration)
        push!(registrations, hover_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/hover' upon `InitializedNotification`"
        end
    else
        # NOTE If hover's `dynamicRegistration` is not supported,
        # it needs to be registered along with initialization in the `InitializeResponse`,
        # since `HoverRegistrationOptions` does not extend `StaticRegistrationOptions`.
    end

    if supports(server, :textDocument, :diagnostic, :dynamicRegistration)
        push!(registrations, diagnostic_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/diagnotic' upon `InitializedNotification`"
        end
    end

    if supports(server, :textDocument, :codeLens, :dynamicRegistration)
        push!(registrations, code_lens_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/codeLens' upon `InitializedNotification`"
        end
    else
        # NOTE If codeLens's `dynamicRegistration` is not supported,
        # it needs to be registered along with initialization in the `InitializeResponse`,
        # since `CodeLensRegistrationOptions` does not extend `StaticRegistrationOptions`.
    end

    if supports(server, :textDocument, :codeAction, :dynamicRegistration)
        push!(registrations, code_action_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/codeAction' upon `InitializedNotification`"
        end
    else
        # NOTE If codeAction's `dynamicRegistration` is not supported,
        # it needs to be registered along with initialization in the `InitializeResponse`,
        # since `CodeActionRegistrationOptions` does not extend `StaticRegistrationOptions`.
    end

    if supports(server, :textDocument, :formatting, :dynamicRegistration)
        push!(registrations, formatting_registration(server))
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/formatting' upon `InitializedNotification`"
        end
    else
        # NOTE If formatting's `dynamicRegistration` is not supported,
        # it needs to be registered along with initialization in the `InitializeResponse`,
        # since `DocumentFormattingRegistrationOptions` does not extend `StaticRegistrationOptions`.
    end

    if supports(server, :textDocument, :rangeFormatting, :dynamicRegistration)
        push!(registrations, range_formatting_registration(server))
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/rangeFormatting' upon `InitializedNotification`"
        end
    else
        # NOTE If rangeFormatting's `dynamicRegistration` is not supported,
        # it needs to be registered along with initialization in the `InitializeResponse`,
        # since `DocumentRangeFormattingRegistrationOptions` does not extend `StaticRegistrationOptions`.
    end

    if supports(server, :textDocument, :rename, :dynamicRegistration)
        push!(registrations, rename_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/rename' upon `InitializedNotification`"
        end
    else
        # NOTE If rename's `dynamicRegistration` is not supported,
        # it needs to be registered along with initialization in the `InitializeResponse`.
    end

    if supports(server, :textDocument, :inlayHint, :dynamicRegistration)
        push!(registrations, inlay_hint_registration(#=static=#false))
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/inlayHint' upon `InitializedNotification`"
        end
    # elseif getcapability(server,
    #     :textDocument, :inlayHint, :dynamicRegistration) === false
    #     # `InlayHintRegistrationOptions` extends `StaticRegistrationOptions`,
    #     # prefer it over the registration with `InitializeResponse` if the client supports it
    #     push!(registrations, inlay_hint_registration(#=static=#true))
    #     if JETLS_DEV_MODE
    #         @info "Statically registering 'textDocument/inlayHint' upon `InitializedNotification`"
    #     end
    end

    if supports(server, :workspace, :didChangeWatchedFiles, :dynamicRegistration)
        push!(registrations, did_change_watched_files_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'workspace/didChangeWatchedFiles' upon `InitializedNotification`"
        end
    else
        # NOTE `workspace/didChangeWatchedFiles` is not supported for static registration
        # so it must be registered dynamically
    end

    if supports(server, :workspace, :didChangeConfiguration, :dynamicRegistration)
        push!(registrations, did_change_configuration_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'workspace/didChangeConfiguration' upon `InitializedNotification`"
        end
    end

    register(server, registrations)

    load_lsp_config!(server, "[LSP] workspace/configuration")

    JETLS_DEV_MODE && show_setup_info("Initialized JETLS with the following setup:")
end
