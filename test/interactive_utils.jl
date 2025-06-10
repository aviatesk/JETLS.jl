using JETLS.URIs2
using JETLS: JET, JETLS, JS, JL
using InteractiveUtils: InteractiveUtils

# interactive entry points for LSAnalyzer

function analyze_call(args...; jetconfigs...)
    analyzer = JETLS.LSAnalyzer(; jetconfigs...)
    return JET.analyze_and_report_call!(analyzer, args...; jetconfigs...)
end
macro analyze_call(ex0...)
    return InteractiveUtils.gen_call_with_extracted_types_and_kwargs(__module__, :analyze_call, ex0)
end

function analyze_and_resolve(s::AbstractString;
                             matcher::Regex  = r"│")
    text, positions = JETLS.get_text_and_positions(s, matcher)
    length(positions) == 1 || error("Multiple positions are found")
    position = only(positions)
    state = JETLS.ServerState()
    mktemp() do filename, io
        uri = filename2uri(filename)
        fileinfo = JETLS.cache_file_info!(state, uri, 1, text, filename)
        context = JETLS.initiate_context!(state, uri)
        analyzer = context.result.analyzer

        mod = JETLS.find_file_module(state, uri, position)

        st_top = JS.build_tree(JL.SyntaxTree, fileinfo.parsed_stream; filename)
        byte = JETLS.xy_to_offset(fileinfo, position)

        # TODO use a proper utility to find "resolvable" node
        # `byte-1` here for allowing `sin│()` to be resolved
        nodes = JETLS.byte_ancestors(st_top, byte-1)
        i = findlast(n -> JS.kind(n) in (JS.K"Identifier", JS.K"."), nodes)
        i === nothing && error("No resolvable node found")
        node = nodes[i]

        JETLS.resolve_node(analyzer, mod, node)
    end
end
