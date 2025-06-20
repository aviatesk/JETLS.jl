# server interaction utilties
# ===========================

const DEFAULT_FLUSH_INTERVAL = 0.05
function yield_to_endpoint(interval=DEFAULT_FLUSH_INTERVAL)
    # HACK: allow JSONRPC endpoint to process queued messages (e.g. work done progress report)
    yield()
    sleep(interval)
end

# TODO memomize computed results?
function supports(server::Server, paths::Symbol...)
    state = server.state
    return isdefined(state, :init_params) &&
        getobjpath(state.init_params.capabilities, paths...) === true
end

"""
Fetch cached FileInfo given an LSclient-provided structure with a URI
"""
get_fileinfo(s::ServerState, uri::URI) = haskey(s.file_cache, uri) ? s.file_cache[uri] : nothing
get_fileinfo(s::ServerState, t::TextDocumentIdentifier) = get_fileinfo(s, t.uri)

"""
    get_context_info(state::ServerState, uri::URI, pos::Position) -> (; mod, analyzer, postprocessor)

Extract context information for a given position in a file.

Returns a named tuple containing:
- `mod::Module`: The module context at the given position
- `analyzer::LSAnalyzer`: The analyzer instance for the file
- `postprocessor::JET.PostProcessor`: The post-processor for fixing `var"..."` strings that users don't need
  to recognize, which are caused by JET implementation details
"""
function get_context_info(state::ServerState, uri::URI, pos::Position)
    analysis_unit = find_analysis_unit_for_uri(state, uri)
    mod = get_context_module(analysis_unit, uri, pos)
    analyzer = get_context_analyzer(analysis_unit, uri)
    postprocessor = get_post_processor(analysis_unit)
    return (; mod, analyzer, postprocessor)
end

get_context_module(::Nothing, ::URI, ::Position) = Main
get_context_module(oos::OutOfScope, ::URI, ::Position) = isdefined(oos, :module_context) ? oos.module_context : Main
function get_context_module(analysis_unit::AnalysisUnit, uri::URI, pos::Position)
    safi = successfully_analyzed_file_info(analysis_unit, uri)
    isnothing(safi) && return Main
    curline = Int(pos.line) + 1
    curmod = Main
    for (range, mod) in safi.module_range_infos
        curline in range || continue
        curmod = mod
    end
    return curmod
end

get_context_analyzer(::Nothing, uri::URI) = LSAnalyzer(uri)
get_context_analyzer(::OutOfScope, uri::URI) = LSAnalyzer(uri)
get_context_analyzer(analysis_unit::AnalysisUnit, ::URI) = analysis_unit.result.analyzer

get_post_processor(::Nothing) = JET.PostProcessor()
get_post_processor(::OutOfScope) = JET.PostProcessor()
get_post_processor(analysis_unit::AnalysisUnit) = JET.PostProcessor(analysis_unit.result.actual2virtual)

function find_analysis_unit_for_uri(state::ServerState, uri::URI)
    haskey(state.analysis_cache, uri) || return nothing
    analysis_info = state.analysis_cache[uri]
    if analysis_info isa OutOfScope
        return analysis_info
    end
    analysis_unit = first(analysis_info)
    for analysis_unit′ in analysis_info
        # prioritize `PackageSourceAnalysisEntry` if exists
        if isa(analysis_unit.entry, PackageSourceAnalysisEntry)
            analysis_unit = analysis_unit′
            break
        end
    end
    return analysis_unit
end
