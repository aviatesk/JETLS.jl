const DECLARATION_REGISTRATION_ID = "jetls-declaration"
const DECLARATION_REGISTRATION_METHOD = "textDocument/declaration"

function declaration_options()
    return DeclarationOptions()
end

function declaration_registration()
    return Registration(;
        id = DECLARATION_REGISTRATION_ID,
        method = DECLARATION_REGISTRATION_METHOD,
        registerOptions = DeclarationRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
        )
    )
end

# For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id = DECLARATION_REGISTRATION_ID,
#     method = DECLARATION_REGISTRATION_METHOD))
# register(currently_running, declaration_registration())

function handle_DeclarationRequest(
        server::Server, msg::DeclarationRequest, cancel_flag::CancelFlag)
    state = server.state
    uri = msg.params.textDocument.uri
    origin_position = adjust_position(state, uri, msg.params.position)

    result = get_file_info(state, uri, cancel_flag)
    if isnothing(result)
        return send(server, DeclarationResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, DeclarationResponse(; id = msg.id, result = nothing, error = result))
    end
    fi = result

    locations, origin_node =
        find_declaration(server, uri, fi, origin_position; fallback_to_definition=true)
    if origin_node === nothing || isempty(locations)
        return send(server, DeclarationResponse(; id = msg.id, result = null))
    end
    if supports(server, :textDocument, :declaration, :linkSupport)
        originSelectionRange, _ = unadjust_range(state, uri, jsobj_to_range(origin_node, fi))
        result = LocationLink[LocationLink(loc, originSelectionRange) for loc in locations]
    else
        result = locations
    end
    return send(server, DeclarationResponse(; id = msg.id, result))
end

"""
    find_declaration(server, uri, fi, pos; soft_scope, fallback_to_definition=false) ->
        (locations::Vector{Location}, origin_node::Union{JS.SyntaxTree,Nothing})

Core routine behind `textDocument/declaration`. Returns the declaration
locations for the symbol at `pos` (source-level `:decl` occurrences —
`import`/`using` sites, `local x`, empty `function foo end`) together
with the syntax-tree node representing the cursor's origin.

With `fallback_to_definition=true`, an empty result falls through to
[`find_definition`](@ref) so the caller never returns an empty
response for a resolvable symbol. This mirrors rust-analyzer's
behavior where "go to declaration" defers to "go to definition" for
languages that don't have a distinct declaration concept for every
binding.
"""
function find_declaration(
        server::Server, uri::URI, fi::FileInfo, pos::Position;
        soft_scope::Bool = is_notebook_cell_uri(server.state, uri),
        fallback_to_definition::Bool = false,
    )
    state = server.state
    st0 = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)
    (; mod) = get_context_info(state, uri, pos)

    binding_result = select_target_binding(st0, offset, mod; caller="find_declaration", soft_scope)
    if !isnothing(binding_result)
        (; ctx3, st3, st0, binding) = binding_result
        binfo = JL.get_binding(ctx3, binding)
        if binfo.kind === :global
            locations = find_global_binding_declarations(server, uri, binfo)
        else
            locations = find_local_binding_declarations(
                state, uri, fi, ctx3, st3, binfo; is_generated=is_generated0(st0))
        end
        isempty(locations) || return locations, binding
    end
    fallback_to_definition || return Location[], nothing
    return find_definition(server, uri, fi, pos; soft_scope)
end

function find_global_binding_declarations(
        server::Server, uri::URI, binfo::JL.BindingInfo
    )
    state = server.state
    uris_to_search = collect_search_uris(server, uri)
    seen_locations = Set{Tuple{URI,Range}}()
    for search_uri in uris_to_search
        fi = @something begin
            get_file_info(state, search_uri)
        end begin
            get_unsynced_file_info!(state, search_uri)
        end continue
        search_st0_top = build_syntax_tree(fi)
        for occurrence in find_global_binding_occurrences!(state, search_uri, fi, search_st0_top, binfo)
            occurrence.kind === :decl || continue
            range, adjusted_uri =
                unadjust_range(state, search_uri, jsobj_to_range(occurrence.tree, fi))
            push!(seen_locations, (adjusted_uri, range))
        end
    end
    locations = Location[]
    for (loc_uri, range) in seen_locations
        push!(locations, Location(; uri = loc_uri, range))
    end
    return locations
end

function find_local_binding_declarations(
        state::ServerState, uri::URI, fi::FileInfo,
        ctx3, st3, binfo::JL.BindingInfo;
        is_generated::Bool = false,
    )
    locations = Location[]
    binding_occurrences = compute_binding_occurrences(ctx3, st3, is_generated)
    haskey(binding_occurrences, binfo) || return locations
    seen_locations = Set{Tuple{URI,Range}}()
    for occurrence in binding_occurrences[binfo]
        occurrence.kind === :decl || continue
        range, adjusted_uri =
            unadjust_range(state, uri, jsobj_to_range(occurrence.tree, fi))
        push!(seen_locations, (adjusted_uri, range))
    end
    for (loc_uri, range) in seen_locations
        push!(locations, Location(; uri = loc_uri, range))
    end
    return locations
end
