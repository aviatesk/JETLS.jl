# server interaction utilities
# ===========================
using Markdown

const DEFAULT_FLUSH_INTERVAL = 0.05
function yield_to_endpoint(interval=DEFAULT_FLUSH_INTERVAL)
    # HACK: allow JSONRPC endpoint to process queued messages (e.g. work done progress report)
    yield()
    sleep(interval)
end

# TODO memomize computed results?

"""
    supports(server::Server, paths::Symbol...) -> Bool
    supports(state::ServerState, paths::Symbol...) -> Bool

Check if the client supports a specific capability.

# Arguments
- `server::Server` or `state::ServerState`: The server or state containing client capabilities
- `paths::Symbol...`: Path of symbols to traverse in the client capabilities object

# Returns
`true` if the capability exists and is explicitly set to `true`, `false` otherwise.

# Examples
```julia
supports(server, :textDocument, :completion, :completionItem, :snippetSupport)
supports(state, :textDocument, :synchronization, :dynamicRegistration)
```

# See also
[`getcapability`](@ref) - Get the actual capability value instead of just checking if it's true
"""
supports(args...) = getcapability(args...) === true

"""
    getcapability(server::Server, paths::Symbol...) -> capability
    getcapability(state::ServerState, paths::Symbol...) -> capability

Get a client capability value by traversing the capability object hierarchy.

# Arguments
- `server::Server` or `state::ServerState`: The server or state containing client capabilities
- `paths::Symbol...`: Path of symbols to traverse in the client capabilities object

# Returns
The capability value at the specified path, or `nothing` if not found.

# Examples
```julia
getcapability(server, :textDocument, :completion, :completionItem, :snippetSupport)
getcapability(state, :general, :positionEncodings)
```

# See also
[`supports`](@ref) - Check if a capability is explicitly set to `true`
"""
getcapability(server::Server, paths::Symbol...) = getcapability(server.state, paths...)
function getcapability(state::ServerState, paths::Symbol...)
    return isdefined(state, :init_params) &&
        getobjpath(state.init_params.capabilities, paths...)
end

"""
    get_file_info(s::ServerState, uri::URI) -> fi::Union{Nothing,FileInfo}
    get_file_info(s::ServerState, t::TextDocumentIdentifier) -> fi::Union{Nothing,FileInfo}

Fetch cached FileInfo given an LSclient-provided structure with a URI
"""
get_file_info(s::ServerState, uri::URI) = get(s.file_cache, uri, nothing)
get_file_info(s::ServerState, t::TextDocumentIdentifier) = get_file_info(s, t.uri)

"""
    get_saved_file_info(s::ServerState, uri::URI) -> fi::Union{Nothing,SavedFileInfo}
    get_saved_file_info(s::ServerState, t::TextDocumentIdentifier) -> fi::Union{Nothing,SavedFileInfo}

Fetch cached saved FileInfo given an LSclient-provided structure with a URI
"""
get_saved_file_info(s::ServerState, uri::URI) = get(s.saved_file_cache, uri, nothing)
get_saved_file_info(s::ServerState, t::TextDocumentIdentifier) = get_saved_file_info(s, t.uri)

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
    safi = @something successfully_analyzed_file_info(analysis_unit, uri) return Main
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

get_post_processor(::Nothing) = LSPostProcessor(JET.PostProcessor())
get_post_processor(::OutOfScope) = LSPostProcessor(JET.PostProcessor())
get_post_processor(analysis_unit::AnalysisUnit) = LSPostProcessor(JET.PostProcessor(analysis_unit.result.actual2virtual))

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

clear_extra_diagnostics!(server::Server, args...) = clear_extra_diagnostics!(server.state, args...)
clear_extra_diagnostics!(state::ServerState, args...) = clear_extra_diagnostics!(state.extra_diagnostics, args...)
function clear_extra_diagnostics!(extra_diagnostics::ExtraDiagnostics, key::ExtraDiagnosticsKey)
    if haskey(extra_diagnostics, key)
        delete!(extra_diagnostics, key)
        return true
    end
    return false
end
function clear_extra_diagnostics!(extra_diagnostics::ExtraDiagnostics, uri::URI) # bulk deletion
    any_deleted = false
    for key in keys(extra_diagnostics)
        if to_uri(key) == uri
            delete!(extra_diagnostics, key)
            any_deleted |= true
        end
    end
    return any_deleted
end
