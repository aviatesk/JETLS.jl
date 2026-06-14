# Code views
# ==========
# Server-computed, read-only Julia documents derived from the user's source —
# currently macro expansion, with `code_typed`, type annotations, etc. planned.
# They are served as virtual documents through the `workspace/textDocumentContent`
# infrastructure in "text-document-content.jl": each view registers its scheme
# there, while the content itself is produced here.

# Macro expansion view
# --------------------
# Unlike cached content (e.g. TestRunner logs), a macro expansion is computed on
# demand from the request URI, which encodes the source document and the byte
# range of the macrocall (or top-level form) to expand.

const MACRO_EXPANSION_CONTENT_PATH = "/macro-expanded.jl"

# The view comes in two modes, distinguished by the `mode` query parameter:
# the default (call-site) expands a single macrocall one level, while `mode=toplevel`
# recursively expands every macrocall in a lowerable top-level form. The byte range names
# the macrocall or the top-level form respectively.
function macro_expansion_content_uri(source_uri::URI, node::SyntaxTreeC; toplevel::Bool=false)
    range = JS.byte_range(node)
    parts = String[
        "source=$(LSP.URIs2.escapeuri(string(source_uri)))",
        "start=$(first(range))",
        "stop=$(last(range))",
    ]
    toplevel && push!(parts, "mode=toplevel")
    return URI(;
        scheme = MACRO_EXPANSION_SCHEME,
        path = MACRO_EXPANSION_CONTENT_PATH,
        query = join(parts, '&'))
end

function find_macrocall_by_range(st0_top::SyntaxTreeC, range::UnitRange{<:Integer})
    return traverse(st0_top) do st::SyntaxTreeC
        JS.kind(st) === JS.K"macrocall" || return nothing
        JS.byte_range(st) == range || return nothing
        return TraversalReturn(st; terminate=true)
    end
end

function find_toplevel_tree_by_range(st0_top::SyntaxTreeC, range::UnitRange{<:Integer})
    return iterate_toplevel_tree(st0_top) do st0::SyntaxTreeC
        JS.byte_range(st0) == range || return nothing
        return TraversalReturn(st0; terminate=true)
    end
end

function macro_expr_from_text(
        text::AbstractString, filename::AbstractString, first_line::Int
    )
    ex = JS.build_tree(Expr, ParseStream!(text); filename, first_line)
    if Meta.isexpr(ex, :toplevel)
        for arg in Iterators.reverse(ex.args)
            arg isa LineNumberNode && continue
            return arg
        end
    end
    return ex
end

# `macroexpand` qualifies globals as `GlobalRef`s for hygiene; ones pointing at
# the expansion's own context module render as noise (`ContextModule.name`).
# Rewrite them to bare symbols so the view reads like hand-written code.
function simplify_macro_expansion!(@nospecialize(x), context_module::Module)
    if x isa GlobalRef
        if x.mod === context_module
            return x.name
        end
        pm = x.mod in (Base, Core) ? x.mod : parentmodule(x.mod)
        if ((pm === Base && Base.isexported(x.mod, x.name)) ||
            (pm === Core && Base.isexported(x.mod, x.name)))
            return x.name
        end
        return x
    elseif x isa Expr
        for i in eachindex(x.args)
            x.args[i] = simplify_macro_expansion!(x.args[i], context_module)
        end
    end
    return x
end

# `macroexpand` threads `LineNumberNode`s through its result: between block
# statements, as each macro call's location (`:macrocall` arg 2), and inside
# nested quotes. `Base.remove_linenums!` drops only the first kind and never
# recurses into quotes, so strip them all for a clean view. A macro call's
# location is cleared to `nothing` rather than removed — the slot is structural,
# and `show` omits it when it is not a `LineNumberNode`.
function strip_macro_expansion_linenums!(@nospecialize(x))
    if x isa Expr
        if x.head === :macrocall && length(x.args) ≥ 2 && x.args[2] isa LineNumberNode
            x.args[2] = nothing
        end
        filter!(@nospecialize(arg) -> !(arg isa LineNumberNode), x.args)
        for arg in x.args
            strip_macro_expansion_linenums!(arg)
        end
    elseif x isa QuoteNode
        strip_macro_expansion_linenums!(x.value)
    end
    return x
end

function print_macrocall_provenance(io::IO, macrocall::SyntaxTreeC)
    buf = IOBuffer()
    JL.showprov(buf, macrocall; note = "the macro call being expanded",
        context_lines_before=3, context_lines_after=3)
    for l in eachsplit(String(take!(buf)), '\n')
        println(io, "# ", l)
    end
    println(io)
    return nothing
end

function print_expanded_code(io::IO, @nospecialize expanded)
    expanded = strip_macro_expansion_linenums!(expanded)
    if Meta.isexpr(expanded, :toplevel)
        for i = eachindex(expanded.args)
            show(io, MIME("text/plain"), expanded.args[i])
            println(io)
        end
    else
        show(io, MIME("text/plain"), expanded)
        println(io)
    end
    return nothing
end

function print_expansion_error_trace(io::IO, @nospecialize(err), bt)
    println(io, "# Expansion error trace:")
    buf = IOBuffer()
    Base.display_error(buf, err, bt)
    for l in eachsplit(String(take!(buf)), '\n')
        println(io, "# ", l)
    end
    println(io)
    return nothing
end

function format_macro_expansion_text(macrocall::SyntaxTreeC, @nospecialize expanded)
    io = IOBuffer()
    println(io, "# Macro call:")
    print_macrocall_provenance(io, macrocall)
    println(io, "# Expanded code view:")
    print_expanded_code(io, expanded)
    return String(take!(io))
end

function format_macro_expansion_error_text(macrocall::SyntaxTreeC, @nospecialize(err), bt)
    io = IOBuffer()
    println(io, "# Macro call:")
    print_macrocall_provenance(io, macrocall)
    print_expansion_error_trace(io, err, bt)
    return String(take!(io))
end

# The recursive top-level view has no single macrocall to anchor a provenance
# block on, so it only notes where the expanded form was defined.
function print_toplevel_expansion_header(io::IO, filename::AbstractString, line::Integer)
    println(io, "# All macros expanded in the top-level form at ", filename, ":", line)
    println(io)
    return nothing
end

function format_toplevel_expansion_text(
        filename::AbstractString, line::Integer, @nospecialize expanded
    )
    io = IOBuffer()
    print_toplevel_expansion_header(io, filename, line)
    print_expanded_code(io, expanded)
    return String(take!(io))
end

function format_toplevel_expansion_error_text(
        filename::AbstractString, line::Integer, @nospecialize(err), bt
    )
    io = IOBuffer()
    print_toplevel_expansion_header(io, filename, line)
    print_expansion_error_trace(io, err, bt)
    return String(take!(io))
end

function macro_expansion_text(server::Server, content_uri::URI)
    params = parse_text_document_content_query(content_uri)
    source = @something get(params, "source", nothing) begin
        return "Missing `source` parameter.\n"
    end
    start = @something tryparse(Int, get(params, "start", "")) begin
        return "Invalid `start` parameter.\n"
    end
    stop = @something tryparse(Int, get(params, "stop", "")) begin
        return "Invalid `stop` parameter.\n"
    end
    toplevel = get(params, "mode", "call") == "toplevel"
    source_uri = URI(source)
    fi = @something get_file_info(server.state, source_uri) begin
        return "Source document is not available: $(string(source_uri))\n"
    end
    st0_top = build_syntax_tree(fi)
    node = if toplevel
        @something find_toplevel_tree_by_range(st0_top, start:stop) begin
            return "Top-level form is no longer available: $(string(source_uri))\n"
        end
    else
        @something find_macrocall_by_range(st0_top, start:stop) begin
            return "Macro call is no longer available: $(string(source_uri))\n"
        end
    end
    pos = offset_to_xy(fi, JS.first_byte(node))
    (; context_module) = get_context_info(server.state, source_uri, pos)
    first_line = Int(pos.line) + 1
    ex = macro_expr_from_text(JS.sourcetext(node), fi.filename, first_line)
    expanded = try
        macroexpand(context_module, ex; recursive=toplevel)
    catch err
        bt = catch_backtrace()
        return toplevel ?
            format_toplevel_expansion_error_text(fi.filename, first_line, err, bt) :
            format_macro_expansion_error_text(node, err, bt)
    end
    expanded = simplify_macro_expansion!(expanded, context_module)
    return toplevel ?
        format_toplevel_expansion_text(fi.filename, first_line, expanded) :
        format_macro_expansion_text(node, expanded)
end

struct OpenMacroExpansionCaller <: RequestCaller end

function request_open_macro_expansion(server::Server, uri::URI)
    if !supports(server, :window, :showDocument, :support)
        show_warning_message(server, "Client does not support `window/showDocument`.")
        return nothing
    end
    id = String(gensym(:ShowMacroExpansionRequest))
    addrequest!(server, id=>OpenMacroExpansionCaller())
    params = ShowDocumentParams(; uri, takeFocus = true)
    return send(server, ShowDocumentRequest(; id, params))
end

function handle_open_macro_expansion_response(
        server::Server, msg::Dict{Symbol,Any}, ::OpenMacroExpansionCaller
    )
    if handle_response_error(server, msg, "open macro expansion")
    elseif haskey(msg, :result)
        result = msg[:result]
        if !(haskey(result, "success") && result["success"] === true)
            show_error_message(server, "Failed to open macro expansion document")
        end
    else
        show_error_message(server, "Unexpected response from macro expansion open request")
    end
end
