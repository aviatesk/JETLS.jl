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
#     id = DEFINITION_REGISTRATION_ID,
#     method = DEFINITION_REGISTRATION_METHOD))
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
    file = file::String
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

function handle_DefinitionRequest(
        server::Server, msg::DefinitionRequest, cancel_flag::CancelFlag)
    state = server.state
    uri = msg.params.textDocument.uri
    origin_position = adjust_position(state, uri, msg.params.position)

    result = get_file_info(state, uri, cancel_flag)
    if isnothing(result)
        return send(server, DefinitionResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, DefinitionResponse(; id = msg.id, result = nothing, error = result))
    end
    fi = result

    st0 = build_syntax_tree(fi)
    offset = xy_to_offset(fi, origin_position)
    (; mod, analyzer) = get_context_info(state, uri, origin_position)

    locationlink_support = supports(server, :textDocument, :definition, :linkSupport)

    target_binding_definitions = select_target_binding_definitions(st0, offset, mod)
    if !isnothing(target_binding_definitions)
        target_binding, definitions = target_binding_definitions
        local result = Location[]
        for definition in definitions
            range, def_uri = unadjust_range(state, uri, jsobj_to_range(definition, fi))
            push!(result, Location(; uri = def_uri, range))
        end
        if locationlink_support
            target_range, _ = unadjust_range(state, uri, jsobj_to_range(target_binding, fi))
            result = LocationLink[LocationLink(loc, target_range) for loc in result]
        end
        return send(server,
            DefinitionResponse(;
                id = msg.id,
                result))
    end

    node = @something select_target_identifier(st0, offset) begin
        return send(server, DefinitionResponse(; id = msg.id, result = null))
    end
    objtyp = resolve_type(analyzer, mod, node)
    objtyp isa Core.Const || return send(server, DefinitionResponse(; id = msg.id, result = null))

    objval = objtyp.val
    originSelectionRange, _ = unadjust_range(state, uri, jsobj_to_range(node, fi))
    if objval isa Module
        if is_location_unknown(objval)
            return send(server, DefinitionResponse(; id = msg.id, result = null))
        else
            local result = unadjust_location(state, uri, Location(objval))
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
            local result = unadjust_location.(Ref(state), Ref(uri), Location.(target_methods))
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
