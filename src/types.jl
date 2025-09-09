const SyntaxTree0 = typeof(JS.build_tree(JL.SyntaxTree, JS.parse!(JS.ParseStream(""))))

abstract type ExtraDiagnosticsKey end
to_uri(key::ExtraDiagnosticsKey) = to_uri_impl(key)::URI
@eval to_key(key::ExtraDiagnosticsKey) = hash(key, $(rand(UInt)))

struct TestsetDiagnosticsKey <: ExtraDiagnosticsKey
    uri::URI
    testset_name::String
    testset_index::Int
end
to_uri_impl(key::TestsetDiagnosticsKey) = key.uri

struct TestsetResult
    result::TestRunnerResult
    key::TestsetDiagnosticsKey
end

struct TestsetInfo
    st0::SyntaxTree0
    result::TestsetResult
    TestsetInfo(st0::SyntaxTree0) = new(st0)
    TestsetInfo(st0::SyntaxTree0, result::TestsetResult) = new(st0, result)
end

struct TestsetInfos
    version::Int # document version
    infos::Vector{TestsetInfo}
end

struct FileInfo
    version::Int
    encoding::LSP.PositionEncodingKind.Ty
    parsed_stream::JS.ParseStream
    syntax_node::JS.SyntaxNode
    syntax_tree0::SyntaxTree0

    function FileInfo(
            version::Int, parsed_stream::JS.ParseStream, filename::AbstractString,
            encoding::LSP.PositionEncodingKind.Ty = LSP.PositionEncodingKind.UTF16
        )
        syntax_node = JS.build_tree(JS.SyntaxNode, parsed_stream; filename)
        syntax_tree0 = JS.build_tree(JL.SyntaxTree, parsed_stream; filename)
        new(version, encoding, parsed_stream, syntax_node, syntax_tree0)
    end
end

function FileInfo( # Constructor for production code (with URI)
        version::Int, parsed_stream::JS.ParseStream, uri::URI,
        encoding::LSP.PositionEncodingKind.Ty = LSP.PositionEncodingKind.UTF16
    )
    filename = @something uri2filename(uri) error(lazy"Unsupported URI: $uri")
    return FileInfo(version, parsed_stream, filename, encoding)
end

function FileInfo( # Constructor for test code (with raw text input and filename)
        version::Int, s::Union{Vector{UInt8},AbstractString}, args...
    )
    return FileInfo(version, ParseStream!(s), args...)
end

struct SavedFileInfo
    parsed_stream::JS.ParseStream
    syntax_node::JS.SyntaxNode
    syntax_tree0::SyntaxTree0

    function SavedFileInfo(parsed_stream::JS.ParseStream, uri::URI)
        filename = @something uri2filename(uri) error(lazy"Unsupported URI: $uri")
        syntax_node = JS.build_tree(JS.SyntaxNode, parsed_stream; filename)
        syntax_tree0 = JS.build_tree(JL.SyntaxTree, parsed_stream; filename)
        new(parsed_stream, syntax_node, syntax_tree0)
    end
end

entryuri(entry::AnalysisEntry) = entryuri_impl(entry)::URI
entryenvpath(entry::AnalysisEntry) = entryenvpath_impl(entry)::Union{Nothing,String}
entrykind(entry::AnalysisEntry) = entrykind_impl(entry)::String
entryjetconfigs(entry::AnalysisEntry) = entryjetconfigs_impl(entry)::Dict{Symbol,Any}

entryenvpath_impl(::AnalysisEntry) = nothing
begin
    local default_jetconfigs = Dict{Symbol,Any}(
        :toplevel_logger => nothing,
        # force concretization of documentation
        :concretization_patterns => [:($(Base.Docs.doc!)(xs__))])
    entryjetconfigs_impl(::AnalysisEntry) = default_jetconfigs
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
begin
    local jetconfigs = Dict{Symbol,Any}(
        :toplevel_logger => nothing,
        :analyze_from_definitions => true,
        :concretization_patterns => [:(x_)])
    entryjetconfigs_impl(::PackageSourceAnalysisEntry) = jetconfigs
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

const ConfigDict = Base.PersistentDict{String, Any}

struct WatchedConfigFiles
    files::Vector{String}
    configs::Vector{ConfigDict}
end
WatchedConfigFiles() = WatchedConfigFiles(String["__DEFAULT_CONFIG__"], ConfigDict[DEFAULT_CONFIG])

function _file_idx(watched_files::WatchedConfigFiles, file::String)
    idx = searchsortedfirst(watched_files.files, file, ConfigFileOrder())
    if idx > length(watched_files.files) || watched_files.files[idx] != file
        return nothing
    end
    return idx
end

Base.keys(watched_files::WatchedConfigFiles) = watched_files.files
Base.values(watched_files::WatchedConfigFiles) = watched_files.configs
Base.length(watched_files::WatchedConfigFiles) = length(watched_files.files)
Base.haskey(watched_files::WatchedConfigFiles, file::String) = _file_idx(watched_files, file) !== nothing

function Base.delete!(watched_files::WatchedConfigFiles, file::String)
    file == "__DEFAULT_CONFIG__" && throw(ArgumentError("Cannot delete `__DEFAULT_CONFIG__` file."))
    idx = _file_idx(watched_files, file)
    idx === nothing && return watched_files
    deleteat!(watched_files.files, idx)
    deleteat!(watched_files.configs, idx)
    return watched_files
end

function Base.setindex!(watched_files::WatchedConfigFiles, config::ConfigDict, file::String)
    idx = searchsortedfirst(watched_files.files, file, ConfigFileOrder())
    if 1 <= idx <= length(watched_files.files) && watched_files.files[idx] == file
        watched_files.configs[idx] = config
        return watched_files
    end
    insert!(watched_files.files, idx, file)
    insert!(watched_files.configs, idx, config)
    return watched_files
end

function Base.getindex(watched_files::WatchedConfigFiles, file::String)
    idx = _file_idx(watched_files, file)
    idx === nothing && throw(KeyError(file))
    return watched_files.configs[idx]
end

function Base.get(watched_files::WatchedConfigFiles, file::String, default)
    idx = _file_idx(watched_files, file)
    idx === nothing && return default
    return watched_files.configs[idx]
end

struct ConfigFileOrder <: Base.Ordering end

mutable struct ConfigManager
    static_settings::ConfigDict             # settings that should be static throughout the server lifetime
    const watched_files::WatchedConfigFiles # watched configuration files
end
ConfigManager() = ConfigManager(ConfigDict(), WatchedConfigFiles())

# Type aliases for document-synchronization caches using `SWContainer` (sequential-only updates)
const FileCache = SWContainer{Base.PersistentDict{URI,FileInfo}}
const SavedFileCache = SWContainer{Base.PersistentDict{URI,SavedFileInfo}}
const TestsetInfosCache = SWContainer{Base.PersistentDict{URI,TestsetInfos}}

mutable struct ServerState
    const workspaceFolders::Vector{URI}
    const file_cache::FileCache # syntactic analysis cache (synced with `textDocument/didChange`)
    const saved_file_cache::SavedFileCache # syntactic analysis cache (synced with `textDocument/didSave`)
    const testsetinfos_cache::TestsetInfosCache
    const analysis_cache::Dict{URI,AnalysisInfo} # entry points for the full analysis (currently not cached really)
    const extra_diagnostics::ExtraDiagnostics
    const currently_requested::Dict{String,RequestCaller}
    const currently_registered::Set{Registered}
    const config_manager::ConfigManager
    encoding::PositionEncodingKind.Ty
    root_path::String
    root_env_path::String
    completion_resolver_info::Tuple{Module,LSPostProcessor}
    init_params::InitializeParams
    function ServerState()
        return new(
            #=workspaceFolders=# URI[],
            #=file_cache=# SWContainer(Base.PersistentDict{URI,FileInfo}()),
            #=saved_file_cache=# SWContainer(Base.PersistentDict{URI,SavedFileInfo}()),
            #=testsetinfos_cache=# SWContainer(Base.PersistentDict{URI,TestsetInfos}()),
            #=analysis_cache=# Dict{URI,AnalysisInfo}(),
            #=extra_diagnostics=# ExtraDiagnostics(),
            #=currently_requested=# Dict{String,RequestCaller}(),
            #=currently_registered=# Set{Registered}(),
            #=config_manager=# ConfigManager(),
            #=encoding=# PositionEncodingKind.UTF16, # initialize with UTF16 (for tests)
        )
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
