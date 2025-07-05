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
function handle_InitializeRequest(server::Server, msg::InitializeRequest)
    state = server.state
    params = state.init_params = msg.params

    workspaceFolders = params.workspaceFolders
    if workspaceFolders !== nothing
        for workspaceFolder in workspaceFolders
            push!(state.workspaceFolders, workspaceFolder.uri)
        end
    else
        rootUri = params.rootUri
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

    if supports(server,
        :textDocument, :completion, :dynamicRegistration)
        completionProvider = nothing # will be registered dynamically
    else
        completionProvider = completion_options()
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/completion' with `InitializeResponse`"
        end
    end

    if supports(server,
        :textDocument, :signatureHelp, :dynamicRegistration)
        signatureHelpProvider = nothing # will be registered dynamically
    else
        signatureHelpProvider = signature_help_options()
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/signatureHelp' with `InitializeResponse`"
        end
    end

    if supports(server,
        :textDocument, :definition, :dynamicRegistration)
        definitionProvider = nothing # will be registered dynamically
    else
        definitionProvider = definition_options()
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/definition' with `InitializeResponse`"
        end
    end

    if supports(server,
        :textDocument, :hover, :dynamicRegistration)
        hoverProvider = nothing # will be registered dynamically
    else
        hoverProvider = hover_options()
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/hover' with `InitializeResponse`"
        end
    end

    if supports(server,
        :textDocument, :diagnostic, :dynamicRegistration)
        diagnosticProvider = nothing # will be registered dynamically
    else
        diagnosticProvider = diagnostic_options()
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/diagnostic' with `InitializeResponse`"
        end
    end

    if supports(server,
        :textDocument, :codeLens, :dynamicRegistration)
        codeLensProvider = nothing # will be registered dynamically
    else
        codeLensProvider = code_lens_options()
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/codeLens' with `InitializeResponse`"
        end
    end

    if supports(server,
        :textDocument, :codeAction, :dynamicRegistration)
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

    result = InitializeResult(;
        capabilities = ServerCapabilities(;
            positionEncoding = PositionEncodingKind.UTF16,
            textDocumentSync = TextDocumentSyncOptions(;
                openClose = true,
                change = TextDocumentSyncKind.Full,
                save = SaveOptions(;
                    includeText = true)),
            completionProvider,
            signatureHelpProvider,
            definitionProvider,
            hoverProvider,
            diagnosticProvider,
            codeLensProvider,
            codeActionProvider,
            executeCommandProvider,
        ),
        serverInfo = (;
            name = "JETLS",
            version = "0.0.0"))

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

    isdefined(state, :init_params) ||
        error("Initialization process not completed") # to exit the server loop

    registrations = Registration[]

    if supports(server,
        :textDocument, :completion, :dynamicRegistration)
        push!(registrations, completion_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/completion' upon `InitializedNotification`"
        end
    else
        # NOTE If completion's `dynamicRegistration` is not supported,
        # it needs to be registered along with initialization in the `InitializeResponse`,
        # since `CompletionRegistrationOptions` does not extend `StaticRegistrationOptions`.
    end

    if supports(server,
        :textDocument, :signatureHelp, :dynamicRegistration)
        push!(registrations, signature_help_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/signatureHelp' upon `InitializedNotification`"
        end
    else
        # NOTE If completion's `dynamicRegistration` is not supported,
        # it needs to be registered along with initialization in the `InitializeResponse`,
        # since `SignatureHelpRegistrationOptions` does not extend `StaticRegistrationOptions`.
    end

    if supports(server,
        :textDocument, :definition, :dynamicRegistration)
        push!(registrations, definition_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/definition' upon `InitializedNotification`"
        end
    else
        # NOTE If definition's `dynamicRegistration` is not supported,
        # it needs to be registered along with initialization in the `InitializeResponse`,
        # since `DefinitionRegistrationOptions` does not extend `StaticRegistrationOptions`.
    end

    if supports(server,
        :textDocument, :hover, :dynamicRegistration)
        push!(registrations, hover_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/hover' upon `InitializedNotification`"
        end
    else
        # NOTE If hover's `dynamicRegistration` is not supported,
        # it needs to be registered along with initialization in the `InitializeResponse`,
        # since `HoverRegistrationOptions` does not extend `StaticRegistrationOptions`.
    end

    if supports(server,
        :textDocument, :diagnostic, :dynamicRegistration)
        push!(registrations, diagnostic_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/diagnotic' upon `InitializedNotification`"
        end
    end

    if supports(server,
        :textDocument, :codeLens, :dynamicRegistration)
        push!(registrations, code_lens_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/codeLens' upon `InitializedNotification`"
        end
    else
        # NOTE If codeLens's `dynamicRegistration` is not supported,
        # it needs to be registered along with initialization in the `InitializeResponse`,
        # since `CodeLensRegistrationOptions` does not extend `StaticRegistrationOptions`.
    end

    if supports(server,
        :textDocument, :codeAction, :dynamicRegistration)
        push!(registrations, code_action_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/codeAction' upon `InitializedNotification`"
        end
    else
        # NOTE If codeAction's `dynamicRegistration` is not supported,
        # it needs to be registered along with initialization in the `InitializeResponse`,
        # since `CodeActionRegistrationOptions` does not extend `StaticRegistrationOptions`.
    end

    register(server, registrations)
end
