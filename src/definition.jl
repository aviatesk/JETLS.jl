const DEFINITION_REGISTRATION_ID = "textDocument-definition"
const DEFINITION_REGISTRATION_METHOD = "textDocument/definition"

function definition_options()
    return DefinitionOptions()
end

function definition_registration()
    return Registration(;
        id = DEFINITION_REGISTRATION_ID,
        method = DEFINITION_REGISTRATION_METHOD,
        registerOptions = TextDocumentRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
        )
    )
end


function is_definition_links_supported(server::Server)
    return getpath(server.state.init_params.capabilities,
        :textDocument, :definition, :linkSupport) === true
end


function handle_DefinitionRequest(server::Server, msg::DefinitionRequest)
    params = msg.params
    text_document = params.textDocument
    position = params.position

    # Mock 
    locations = [
        Location(;
        uri = text_document.uri,
        range = Range(;
            start = Position(; line = 0, character = 0),
            var"end" = Position(; line = 1, character = 10)
        )
    ),
        Location(;
        uri = text_document.uri,
        range = Range(;
            start = Position(; line = 4, character = 0),
            var"end" = Position(; line = 5, character = 10)
        )
    )]

    if is_definition_links_supported(server)
        @info "Definition links are supported by the client."
        response = DefinitionResponse(;
            id = msg.id,
            result = map(
                loc -> LocationLink(;
                    targetUri = loc.uri,
                    targetRange = loc.range,
                    targetSelectionRange = loc.range,
                    originSelectionRange = Range(;
                        start = position, var"end" = position
                    )
                ), locations
            )
        )

    else
        @info "Definition links are not supported by the client."
        response = DefinitionResponse(;
            id = msg.id,
            result = locations
        )
    end

    send(server, response)
end