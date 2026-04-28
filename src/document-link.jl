const DOCUMENT_LINK_REGISTRATION_ID = "jetls-document-link"
const DOCUMENT_LINK_REGISTRATION_METHOD = "textDocument/documentLink"

function document_link_options()
    return DocumentLinkOptions()
end

function document_link_registration()
    return Registration(;
        id = DOCUMENT_LINK_REGISTRATION_ID,
        method = DOCUMENT_LINK_REGISTRATION_METHOD,
        registerOptions = DocumentLinkRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR))
end

# # For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id = DOCUMENT_LINK_REGISTRATION_ID,
#     method = DOCUMENT_LINK_REGISTRATION_METHOD))
# register(currently_running, document_link_registration())

function handle_DocumentLinkRequest(
        server::Server, msg::DocumentLinkRequest, cancel_flag::CancelFlag
    )
    state = server.state
    uri = msg.params.textDocument.uri
    result = get_file_info(state, uri, cancel_flag)
    if isnothing(result)
        return send(server, DocumentLinkResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server,
            DocumentLinkResponse(; id = msg.id, result = nothing, error = result))
    end
    fi = result

    links = DocumentLink[]
    collect_include_document_links!(links, state, uri, fi)
    return send(server,
        DocumentLinkResponse(;
            id = msg.id,
            result = @somereal links null))
end

function collect_include_document_links!(
        links::Vector{DocumentLink}, state::ServerState, uri::URI, fi::FileInfo
    )
    basedir = dirname(uri2filename(uri))
    st0_top = build_syntax_tree(fi)
    traverse(st0_top) do node::JS.SyntaxTree
        string_node = @something include_path_string_node(node) return
        resolved = @something resolve_path_string_literal(string_node, basedir) return
        range, _ = unadjust_range(state, uri, jsobj_to_range(string_node, fi))
        push!(links, DocumentLink(; range, target = filename2uri(resolved.path)))
        return traversal_no_recurse
    end
    return links
end

# If `node` is an `include("path")` call with a single non-interpolated string
# argument, return that `K"String"` node. Otherwise return `nothing`.
# Interpolated strings (e.g. `"$x.jl"`) parse into `K"string"` and are skipped.
function include_path_string_node(node::JS.SyntaxTree)
    JS.kind(node) === JS.K"call" || return nothing
    JS.numchildren(node) == 2 || return nothing
    callee = node[1]
    JS.kind(callee) === JS.K"Identifier" || return nothing
    JS.hasattr(callee, :name_val) || return nothing
    callee.name_val in ("include", "include_dependency") || return nothing
    arg = node[2]
    JS.kind(arg) === JS.K"String" || return nothing
    return arg
end
