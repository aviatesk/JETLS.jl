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

function find_file_module!(state::ServerState, uri::URI, pos::Position)
    mod = find_file_module(state, uri, pos)
    state.completion_module = mod
    return mod
end
function find_file_module(state::ServerState, uri::URI, pos::Position)
    analysis_unit = find_analysis_unit_for_uri(state, uri)
    analysis_unit === nothing && return Main
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

function find_analysis_unit_for_uri(state::ServerState, uri::URI)
    haskey(state.analysis_cache, uri) || return nothing
    analysis_info = state.analysis_cache[uri]
    analysis_info isa OutOfScope && return nothing
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
