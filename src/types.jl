const SyntaxTree0 = typeof(JS.build_tree(JL.SyntaxTree, JS.parse!(JS.ParseStream(""))))

abstract type ExtraDiagnosticsKey end
to_file_info(key::ExtraDiagnosticsKey) = to_file_info_impl(key)::FileInfo
@eval to_key(key::ExtraDiagnosticsKey) = hash(key, $(rand(UInt)))

struct _TestsetDiagnosticsKey{FileInfo} <: ExtraDiagnosticsKey
    testset_name::String
    idx::Int
    fi::FileInfo
end
to_file_info_impl(key::_TestsetDiagnosticsKey) = key.fi

struct _TestsetResult{FileInfo}
    result::TestRunnerResult
    key::_TestsetDiagnosticsKey{FileInfo}
end

struct _TestsetInfo{FileInfo}
    st0::SyntaxTree0
    result::_TestsetResult{FileInfo}
    _TestsetInfo{FileInfo}(st0::SyntaxTree0) where {FileInfo} = new{FileInfo}(st0)
    _TestsetInfo{FileInfo}(st0::SyntaxTree0, result::_TestsetResult{FileInfo}) where {FileInfo} = new{FileInfo}(st0, result)
end

mutable struct FileInfo
    version::Int
    parsed_stream::JS.ParseStream
    # filled after cached
    syntax_node::Dict{Any,JS.SyntaxNode}
    syntax_tree0::Dict{Any,SyntaxTree0}
    testsetinfos::Vector{_TestsetInfo{FileInfo}}
    FileInfo(version::Int, parsed_stream::JS.ParseStream) =
        new(version, parsed_stream, Dict{Any,JS.SyntaxNode}(), Dict{Any,SyntaxTree0}(), TestsetInfo[])
end

const TestsetDiagnosticsKey = _TestsetDiagnosticsKey{FileInfo}
const TestsetResult = _TestsetResult{FileInfo}
const TestsetInfo = _TestsetInfo{FileInfo}

mutable struct SavedFileInfo
    parsed_stream::JS.ParseStream
    # filled after cached
    syntax_node::Dict{Any,JS.SyntaxNode}
    syntax_tree0::Dict{Any,SyntaxTree0}
    SavedFileInfo(parsed_stream::JS.ParseStream) =
        new(parsed_stream, Dict{Any,JS.SyntaxNode}(), Dict{Any,SyntaxTree0}())
end

function build_tree! end

entryuri(entry::AnalysisEntry) = entryuri_impl(entry)::URI
entryenvpath(entry::AnalysisEntry) = entryenvpath_impl(entry)::Union{Nothing,String}
entrykind(entry::AnalysisEntry) = entrykind_impl(entry)::String
entryjetconfigs(entry::AnalysisEntry) = entryjetconfigs_impl(entry)::Dict{Symbol,Any}

entryenvpath_impl(::AnalysisEntry) = nothing
let default_jetconfigs = Dict{Symbol,Any}(
        :toplevel_logger => nothing,
        # force concretization of documentation
        :concretization_patterns => [:($(Base.Docs.doc!)(xs__))])
    global entryjetconfigs_impl(::AnalysisEntry) = default_jetconfigs
end

struct ScriptAnalysisEntry <: AnalysisEntry
    uri::URI
end
entryuri_impl(entry::ScriptAnalysisEntry) = entry.uri
entryenvpath_impl(::ScriptAnalysisEntry) = nothing
entrykind_impl(::ScriptAnalysisEntry) = "script"
struct ScriptInEnvAnalysisEntry <: AnalysisEntry
    env_path::String
    uri::URI
end
entryuri_impl(entry::ScriptInEnvAnalysisEntry) = entry.uri
entryenvpath_impl(entry::ScriptInEnvAnalysisEntry) = entry.env_path
entrykind_impl(::ScriptInEnvAnalysisEntry) = "script in env"
struct PackageSourceAnalysisEntry <: AnalysisEntry
    env_path::String
    pkgfileuri::URI
    pkgid::Base.PkgId
end
entryuri_impl(entry::PackageSourceAnalysisEntry) = entry.pkgfileuri
entryenvpath_impl(entry::PackageSourceAnalysisEntry) = entry.env_path
entrykind_impl(::PackageSourceAnalysisEntry) = "pkg src"
let jetconfigs = Dict{Symbol,Any}(
        :toplevel_logger => nothing,
        :analyze_from_definitions => true,
        :concretization_patterns => [:(x_)])
    global entryjetconfigs_impl(entry::PackageSourceAnalysisEntry) = jetconfigs
end
struct PackageTestAnalysisEntry <: AnalysisEntry
    env_path::String
    runtestsuri::URI
end
entryuri_impl(entry::PackageTestAnalysisEntry) = entry.runtestsuri
entryenvpath_impl(entry::PackageTestAnalysisEntry) = entry.env_path
entrykind_impl(::PackageTestAnalysisEntry) = "pkg test"

struct FullAnalysisInfo{E<:AnalysisEntry}
    entry::E
    token::Union{Nothing,ProgressToken}
    reanalyze::Bool
    n_files::Int
end

const URI2Diagnostics = Dict{URI,Vector{Diagnostic}}

mutable struct FullAnalysisResult
    staled::Bool
    actual2virtual::JET.Actual2Virtual
    analyzer::LSAnalyzer
    interp
    const uri2diagnostics::URI2Diagnostics
    const analyzed_file_infos::Dict{URI,JET.AnalyzedFileInfo}
    const successfully_analyzed_file_infos::Dict{URI,JET.AnalyzedFileInfo}
end

struct AnalysisUnit
    entry::AnalysisEntry
    result::FullAnalysisResult
end

analyzed_file_uris(analysis_unit::AnalysisUnit) = keys(analysis_unit.result.analyzed_file_infos)

function successfully_analyzed_file_info(analysis_unit::AnalysisUnit, uri::URI)
    return get(analysis_unit.result.successfully_analyzed_file_infos, uri, nothing)
end

struct OutOfScope
    module_context::Module
    OutOfScope() = new() # really unknown context
    OutOfScope(module_context::Module) = new(module_context)
end

const AnalysisInfo = Union{Set{AnalysisUnit},OutOfScope}

abstract type RequestCaller end

struct RunFullAnalysisCaller <: RequestCaller
    uri::URI
    onsave::Bool
    token::ProgressToken
end

struct Registered
    id::String
    method::String
end

struct ExtraDiagnostics
    keys::Dict{UInt,ExtraDiagnosticsKey}
    values::Dict{UInt,URI2Diagnostics}
end
ExtraDiagnostics() = ExtraDiagnostics(Dict{UInt,ExtraDiagnosticsKey}(), Dict{UInt,URI2Diagnostics}())

Base.haskey(extra_diagnostics::ExtraDiagnostics, key::ExtraDiagnosticsKey) =
    haskey(extra_diagnostics.keys, to_key(key))
Base.getindex(extra_diagnostics::ExtraDiagnostics, key::ExtraDiagnosticsKey) =
    extra_diagnostics.values[to_key(key)]
function Base.setindex!(extra_diagnostics::ExtraDiagnostics, val::URI2Diagnostics, key::ExtraDiagnosticsKey)
    k = to_key(key)
    extra_diagnostics.keys[k] = key
    return extra_diagnostics.values[k] = val
end
function Base.get(extra_diagnostics::ExtraDiagnostics, key::ExtraDiagnosticsKey, default)
    if haskey(extra_diagnostics, key)
        return extra_diagnostics[key]
    end
    return default
end
function Base.get(f, extra_diagnostics::ExtraDiagnostics, key::ExtraDiagnosticsKey)
    if haskey(extra_diagnostics, key)
        return extra_diagnostics[key]
    end
    return f()
end
function Base.get!(extra_diagnostics::ExtraDiagnostics, key::ExtraDiagnosticsKey, default::URI2Diagnostics)
    if haskey(extra_diagnostics, key)
        return extra_diagnostics[key]
    end
    return extra_diagnostics[key] = default
end
function Base.get!(f, extra_diagnostics::ExtraDiagnostics, key::ExtraDiagnosticsKey)
    if haskey(extra_diagnostics, key)
        return extra_diagnostics[key]
    end
    return extra_diagnostics[key] = f()
end
Base.keys(extra_diagnostics::ExtraDiagnostics) = values(extra_diagnostics.keys)
Base.values(extra_diagnostics::ExtraDiagnostics) = values(extra_diagnostics.values)
function Base.push!(extra_diagnostics::ExtraDiagnostics, (key, val)::Pair{ExtraDiagnosticsKey,URI2Diagnostics})
    k = to_key(key)
    push!(extra_diagnostics.keys, k => val)
    push!(extra_diagnostics.values, k => val)
end
function Base.delete!(extra_diagnostics::ExtraDiagnostics, key::ExtraDiagnosticsKey)
    k = to_key(key)
    delete!(extra_diagnostics.keys, k)
    delete!(extra_diagnostics.values, k)
end

Base.length(extra_diagnostics::ExtraDiagnostics) = length(extra_diagnostics.keys)
Base.eltype(::Type{ExtraDiagnostics}) = Pair{ExtraDiagnosticsKey,URI2Diagnostics}
Base.keytype(::Type{ExtraDiagnostics}) = ExtraDiagnosticsKey
Base.valtype(::Type{ExtraDiagnostics}) = URI2Diagnostics
function Base.iterate(extra_diagnostics::ExtraDiagnostics, keysiter=(keys(extra_diagnostics.keys),))
    next = @something iterate(keysiter...) return nothing
    k, nextstate = next
    nextkeysiter = (keysiter[1], nextstate)
    key = extra_diagnostics.keys[k]
    val = extra_diagnostics.values[k]
    return (key => val, nextkeysiter)
end

struct LSPostProcessor
    inner::JET.PostProcessor
    LSPostProcessor(inner::JET.PostProcessor) = new(inner)
end
LSPostProcessor() = LSPostProcessor(JET.PostProcessor())

mutable struct ServerState
    const workspaceFolders::Vector{URI}
    const file_cache::Dict{URI,FileInfo} # syntactic analysis cache (synced with `textDocument/didChange`)
    const saved_file_cache::Dict{URI,SavedFileInfo} # syntactic analysis cache (synced with `textDocument/didSave`)
    const analysis_cache::Dict{URI,AnalysisInfo} # entry points for the full analysis (currently not cached really)
    const extra_diagnostics::ExtraDiagnostics
    const currently_requested::Dict{String,RequestCaller}
    const currently_registered::Set{Registered}
    root_path::String
    root_env_path::String
    completion_resolver_info::Tuple{Module,LSPostProcessor}
    init_params::InitializeParams
    function ServerState()
        return new(
            #=workspaceFolders=# URI[],
            #=file_cache=# Dict{URI,FileInfo}(),
            #=saved_file_cache=# Dict{URI,SavedFileInfo}(),
            #=analysis_cache=# Dict{URI,AnalysisInfo}(),
            #=extra_diagnostics=# ExtraDiagnostics(),
            #=currently_requested=# Dict{String,RequestCaller}(),
            #=currently_registered=# Set{Registered}())
    end
end

struct Server{Callback}
    endpoint::Endpoint
    callback::Callback
    state::ServerState
    function Server(callback::Callback, endpoint::Endpoint) where Callback
        return new{Callback}(
            endpoint,
            callback,
            ServerState())
    end
end
Server() = Server(Returns(nothing), LSEndpoint(IOBuffer(), IOBuffer())) # used for tests

"""
    send(state::ServerState, msg)

Send a message to the client through the server `state.endpoint`

This function is used by each handler that processes messages sent from the client,
as well as for sending requests and notifications from the server to the client.
"""
function send(server::Server, @nospecialize msg)
    JSONRPC.send(server.endpoint, msg)
    server.callback !== nothing && server.callback(:sent, msg)
    nothing
end
