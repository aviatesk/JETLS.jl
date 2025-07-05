const DEFINITION_REGISTRATION_ID = "jetls-definition"
const DEFINITION_REGISTRATION_METHOD = "textDocument/definition"

function definition_options()
    return DefinitionOptions()
end

function definition_registration()
    return Registration(;
        id = DEFINITION_REGISTRATION_ID,
        method = DEFINITION_REGISTRATION_METHOD,
        registerOptions = DefinitionRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
        )
    )
end

# For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id=DEFINITION_REGISTRATION_ID,
#     method=DEFINITION_REGISTRATION_METHOD))
# register(currently_running, definition_registration())

is_location_unknown(m::Method) = Base.updated_methodloc(m)[2] ≤ 0
function is_location_unknown(mod::Module)
    (; file, line) = Base.moduleloc(mod)
    return line ≤ 0 || file === Symbol("")
end

"""
Get the range of a method. (will be deprecated in the future)

TODO (later): get the correct range of the method definition.
For now, it just returns the first line of the method
"""
function LSP.Location(m::Method)
    file, line = functionloc(m)
    file = to_full_path(file)
    return Location(;
        uri = filename2uri(file),
        range = Range(;
            start = Position(; line = line - 1, character = 0),
            var"end" = Position(; line = line - 1, character = Int(typemax(Int32)))))
end

function LSP.Location(mod::Module)
    (; file, line) = Base.moduleloc(mod)
    uri = filename2uri(to_full_path(file))
    return Location(;
        uri,
        range = Range(;
            start = Position(; line = line - 1, character = 0),
            var"end" = Position(; line = line - 1, character = Int(typemax(Int32)))))
end

LSP.LocationLink(loc::Location, originSelectionRange::Range) =
    LocationLink(;
        targetUri = loc.uri,
        targetRange = loc.range,
        targetSelectionRange = loc.range,
        originSelectionRange)

function handle_DefinitionRequest(server::Server, msg::DefinitionRequest)
    origin_position = msg.params.position
    uri = msg.params.textDocument.uri

    fi = get_file_info(server.state, uri)
    if fi === nothing
        return send(server,
            DefinitionResponse(;
                id = msg.id,
                result = nothing,
                error = file_cache_error(uri)))
    end

    st0 = build_tree!(JL.SyntaxTree, fi)
    offset = xy_to_offset(fi, origin_position)

    locationlink_support = supports(server, :textDocument, :definition, :linkSupport)

    target_binding_definitions = select_target_binding_definitions(st0, offset)
    if !isnothing(target_binding_definitions)
        target_binding, definitions = target_binding_definitions
        local result = Location[
            Location(; uri, range = get_source_range(definition))
            for definition in definitions]
        if locationlink_support
            result = LocationLink[
                LocationLink(loc, get_source_range(target_binding))
                for loc in result]
        end
        return send(server,
            DefinitionResponse(;
                id = msg.id,
                result))
    end

    node = select_target_node(st0, offset)
    if node === nothing
        return send(server, DefinitionResponse(; id = msg.id, result = null))
    end
    (; mod, analyzer) = get_context_info(server.state, uri, origin_position)
    objtyp = resolve_type(analyzer, mod, node)
    objtyp isa Core.Const || return send(server, DefinitionResponse(; id = msg.id, result = null))

    objval = objtyp.val
    originSelectionRange = get_source_range(node)
    if objval isa Module
        if is_location_unknown(objval)
            return send(server, DefinitionResponse(; id = msg.id, result = null))
        else
            local result = Location(objval)
            if locationlink_support
                result = LocationLink[LocationLink(result, originSelectionRange)] # only `result::Vector{LocationLink}` is supported
            end
            return send(server,
                DefinitionResponse(;
                    id = msg.id,
                    result))
        end
    else
        target_methods = filter(!is_location_unknown, unique(Base.updated_methodloc, methods(objtyp.val)))
        if isempty(target_methods)
            return send(server, DefinitionResponse(; id = msg.id, result = null))
        else
            local result = Location.(target_methods)
            if locationlink_support
                result = LocationLink.(result, Ref(originSelectionRange))
            end
            return send(server,
                DefinitionResponse(;
                    id = msg.id,
                    result))
        end
    end
end
