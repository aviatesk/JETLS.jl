const SyntaxTree0 = typeof(JS.build_tree(JL.SyntaxTree, JS.parse!(JS.ParseStream(""))))

struct FileInfo
    version::Int
    parsed_stream::JS.ParseStream
    filename::String
    encoding::LSP.PositionEncodingKind.Ty

    function FileInfo(
            version::Int, parsed_stream::JS.ParseStream, filename::AbstractString,
            encoding::LSP.PositionEncodingKind.Ty = LSP.PositionEncodingKind.UTF16
        )
        new(version, parsed_stream, filename, encoding)
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

    function SavedFileInfo(parsed_stream::JS.ParseStream, uri::URI)
        filename = @something uri2filename(uri) error(lazy"Unsupported URI: $uri")
        syntax_node = JS.build_tree(JS.SyntaxNode, parsed_stream; filename)
        new(parsed_stream, syntax_node)
    end
end

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

mutable struct CancelFlag
    @atomic cancelled::Bool
    # on_cancelled::LWContainer{IdSet{Any}, LWStats} for cancellation callback?
end
const DUMMY_CANCEL_FLAG = CancelFlag(false)

function cancel!(cancel_flag::CancelFlag)
    @atomic :release cancel_flag.cancelled = true
end

is_cancelled(cancel_flag::CancelFlag) = @atomic :acquire cancel_flag.cancelled

struct CancellableToken
    token::ProgressToken
    cancel_flag::CancelFlag
end

const CurrentlyHandled = Dict{Union{Int,String}, CancelFlag}

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
    global entryjetconfigs_impl(::PackageSourceAnalysisEntry) = jetconfigs
end

struct PackageTestAnalysisEntry <: AnalysisEntry
    env_path::String
    runtestsuri::URI
end
entryuri_impl(entry::PackageTestAnalysisEntry) = entry.runtestsuri
entryenvpath_impl(entry::PackageTestAnalysisEntry) = entry.env_path
entrykind_impl(::PackageTestAnalysisEntry) = "pkg test"

const URI2Diagnostics = Dict{URI,Vector{Diagnostic}}

struct AnalysisResult
    entry::AnalysisEntry
    uri2diagnostics::URI2Diagnostics
    analyzer::LSAnalyzer
    analyzed_file_infos::Dict{URI,JET.AnalyzedFileInfo}
    actual2virtual::JET.Actual2Virtual
end

analyzed_file_uris(analysis_result::AnalysisResult) = keys(analysis_result.analyzed_file_infos)

analyzed_file_info(analysis_result::AnalysisResult, uri::URI) = get(analysis_result.analyzed_file_infos, uri, nothing)

struct OutOfScope
    module_context::Module
    OutOfScope() = new() # really unknown context
    OutOfScope(module_context::Module) = new(module_context)
end

# TODO support multiple analysis units, which can happen if this file is included from multiple different analysis_units
const AnalysisInfo = Union{AnalysisResult,OutOfScope}

struct AnalysisRequest
    entry::AnalysisEntry
    uri::URI
    generation::Int
    cancellable_token::Union{Nothing,CancellableToken}
    notify::Bool
    prev_analysis_result::Union{Nothing,AnalysisResult}
    completion::Base.Event
    function AnalysisRequest(
            entry::AnalysisEntry,
            uri::URI,
            generation::Int,
            cancellable_token::Union{Nothing,CancellableToken},
            notify::Bool,
            prev_analysis_result::Union{Nothing,AnalysisResult},
            completion::Base.Event = Base.Event()
        )
        return new(entry, uri, generation, cancellable_token, notify, prev_analysis_result, completion)
    end
end

const AnalysisCache = LWContainer{Dict{URI,AnalysisInfo}, LWStats}
const PendingAnalyses = CASContainer{Dict{AnalysisEntry,Union{Nothing,AnalysisRequest}}, CASStats}
const CurrentGenerations = CASContainer{Dict{AnalysisEntry,Int}}
const AnalyzedGenerations = CASContainer{Dict{AnalysisEntry,Int}}
const DebouncedRequests = LWContainer{Dict{AnalysisEntry,Timer}, LWStats}
const InstantiatedEnvs = LWContainer{Dict{String,Union{Nothing,Tuple{Base.PkgId,URI}}}}

struct AnalysisManager
    cache::AnalysisCache
    pending_analyses::PendingAnalyses
    queue::Channel{AnalysisRequest}
    worker_tasks::Vector{Task}
    current_generations::CurrentGenerations
    analyzed_generations::AnalyzedGenerations
    debounced::DebouncedRequests
    instantiated_envs::InstantiatedEnvs
    function AnalysisManager(n_workers::Int)
        return new(
            AnalysisCache(Dict{URI,AnalysisInfo}()),
            PendingAnalyses(Dict{AnalysisEntry,Union{Nothing,AnalysisRequest}}()),
            Channel{AnalysisRequest}(Inf),
            Vector{Task}(undef, n_workers),
            CurrentGenerations(Dict{AnalysisEntry,Int}()),
            AnalyzedGenerations(Dict{AnalysisEntry,Int}()),
            DebouncedRequests(Dict{AnalysisEntry,Timer}()),
            InstantiatedEnvs(Dict{String,Union{Nothing,Tuple{Base.PkgId,URI}}}())
        )
    end
end

abstract type RequestCaller end
cancellable_token(::RequestCaller) = nothing

struct Registered
    id::String
    method::String
end

struct ExtraDiagnosticsData
    keys::Dict{UInt,ExtraDiagnosticsKey}
    values::Dict{UInt,URI2Diagnostics}
end
ExtraDiagnosticsData() = ExtraDiagnosticsData(Dict{UInt,ExtraDiagnosticsKey}(), Dict{UInt,URI2Diagnostics}())
function ExtraDiagnosticsData(data::ExtraDiagnosticsData, (key, val))
    new_data = copy(data)
    new_data[key] = val
    return new_data
end

Base.copy(extra_diagnostics::ExtraDiagnosticsData) = ExtraDiagnosticsData(copy(extra_diagnostics.keys), copy(extra_diagnostics.values))

Base.haskey(extra_diagnostics::ExtraDiagnosticsData, key::ExtraDiagnosticsKey) =
    haskey(extra_diagnostics.keys, to_key(key))
Base.getindex(extra_diagnostics::ExtraDiagnosticsData, key::ExtraDiagnosticsKey) =
    extra_diagnostics.values[to_key(key)]
function Base.setindex!(extra_diagnostics::ExtraDiagnosticsData, val::URI2Diagnostics, key::ExtraDiagnosticsKey)
    k = to_key(key)
    extra_diagnostics.keys[k] = key
    return extra_diagnostics.values[k] = val
end
function Base.get(extra_diagnostics::ExtraDiagnosticsData, key::ExtraDiagnosticsKey, default)
    if haskey(extra_diagnostics, key)
        return extra_diagnostics[key]
    end
    return default
end
function Base.get(f, extra_diagnostics::ExtraDiagnosticsData, key::ExtraDiagnosticsKey)
    if haskey(extra_diagnostics, key)
        return extra_diagnostics[key]
    end
    return f()
end
function Base.get!(extra_diagnostics::ExtraDiagnosticsData, key::ExtraDiagnosticsKey, default::URI2Diagnostics)
    if haskey(extra_diagnostics, key)
        return extra_diagnostics[key]
    end
    return extra_diagnostics[key] = default
end
function Base.get!(f, extra_diagnostics::ExtraDiagnosticsData, key::ExtraDiagnosticsKey)
    if haskey(extra_diagnostics, key)
        return extra_diagnostics[key]
    end
    return extra_diagnostics[key] = f()
end
Base.keys(extra_diagnostics::ExtraDiagnosticsData) = values(extra_diagnostics.keys)
Base.values(extra_diagnostics::ExtraDiagnosticsData) = values(extra_diagnostics.values)
function Base.push!(extra_diagnostics::ExtraDiagnosticsData, (key, val)::Pair{ExtraDiagnosticsKey,URI2Diagnostics})
    k = to_key(key)
    push!(extra_diagnostics.keys, k => val)
    push!(extra_diagnostics.values, k => val)
end
function Base.delete!(extra_diagnostics::ExtraDiagnosticsData, key::ExtraDiagnosticsKey)
    k = to_key(key)
    delete!(extra_diagnostics.keys, k)
    delete!(extra_diagnostics.values, k)
end

Base.length(extra_diagnostics::ExtraDiagnosticsData) = length(extra_diagnostics.keys)
Base.eltype(::Type{ExtraDiagnosticsData}) = Pair{ExtraDiagnosticsKey,URI2Diagnostics}
Base.keytype(::Type{ExtraDiagnosticsData}) = ExtraDiagnosticsKey
Base.valtype(::Type{ExtraDiagnosticsData}) = URI2Diagnostics
function Base.iterate(extra_diagnostics::ExtraDiagnosticsData, keysiter=(keys(extra_diagnostics.keys),))
    next = @something iterate(keysiter...) return nothing
    k, nextstate = next
    nextkeysiter = (keysiter[1], nextstate)
    key = extra_diagnostics.keys[k]
    val = extra_diagnostics.values[k]
    return (key => val, nextkeysiter)
end

"""
To extend configuration options, define new `@option struct`s here:

    @option struct NewConfig <: ConfigSection
        field1::Maybe{Type1}  # Maybe{T} from Configurations.jl allows optional fields
        field2::Maybe{Type2}
    end

All fields must be wrapped in `Maybe{}` to distinguish between cases of
"no configuration set" and those of "user has set some configuration",
which are important for our configuration notification system to work.

Note that `TypeX` should not be defined to include the possibility of being `nothing` like `Union{Nothing,TypeX}`.
In such cases, a further inner configuration level should be used.

Then, overload the following methods properly:
- `default_config(::Type{NewConfig}) -> NewConfig`
  Returns the default configuration values.

Finally, add the new config section to `JETLSConfig` struct below.
"""
abstract type ConfigSection end

_unwrap_maybe(::Type{Maybe{S}}) where {S} = S
_unwrap_maybe(::Type{T}) where {T} = T

@option struct FullAnalysisConfig <: ConfigSection
    debounce::Maybe{Float64}
    auto_instantiate::Maybe{Bool}
end
default_config(::Type{FullAnalysisConfig}) = FullAnalysisConfig(1.0, true)

@option struct TestRunnerConfig <: ConfigSection
    executable::Maybe{String}
end
default_config(::Type{TestRunnerConfig}) = TestRunnerConfig(@static Sys.iswindows() ? "testrunner.bat" : "testrunner")

@option "custom" struct CustomFormatterConfig
    executable::Maybe{String}
    executable_range::Maybe{String}
end

const FormatterConfig = Union{String,CustomFormatterConfig}
default_config(::Type{FormatterConfig}) = "Runic"

function default_executable(formatter::String)
    if formatter == "Runic"
        return @static Sys.iswindows() ? "runic.bat" : "runic"
    elseif formatter == "JuliaFormatter"
        return @static Sys.iswindows() ? "jlfmt.bat" : "jlfmt"
    else
        return nothing
    end
end

const DIAGNOSTIC_SOURCE = "JETLS"

const VALID_DIAGNOSTIC_CATEGORIES = Set{String}((
    "syntax",
    "lowering",
    "toplevel",
    "inference",
    "testrunner",
))

const SYNTAX_DIAGNOSTIC_CODE = "syntax/parse-error"
const LOWERING_UNUSED_ARGUMENT_CODE = "lowering/unused-argument"
const LOWERING_UNUSED_LOCAL_CODE = "lowering/unused-local"
const LOWERING_ERROR_CODE = "lowering/error"
const LOWERING_MACRO_EXPANSION_ERROR_CODE = "lowering/macro-expansion-error"
const TOPLEVEL_ERROR_CODE = "toplevel/error"
const INFERENCE_UNDEF_GLOBAL_VAR_CODE = "inference/undef-global-var"
const INFERENCE_UNDEF_LOCAL_VAR_CODE = "inference/undef-local-var"
const INFERENCE_UNDEF_STATIC_PARAM_CODE = "inference/undef-static-param" # currently not reported
const TESTRUNNER_TEST_FAILURE_CODE = "testrunner/test-failure"

const ALL_DIAGNOSTIC_CODES = Set{String}(String[
    SYNTAX_DIAGNOSTIC_CODE,
    LOWERING_UNUSED_ARGUMENT_CODE,
    LOWERING_UNUSED_LOCAL_CODE,
    LOWERING_ERROR_CODE,
    LOWERING_MACRO_EXPANSION_ERROR_CODE,
    TOPLEVEL_ERROR_CODE,
    INFERENCE_UNDEF_GLOBAL_VAR_CODE,
    INFERENCE_UNDEF_LOCAL_VAR_CODE,
    INFERENCE_UNDEF_STATIC_PARAM_CODE,
    TESTRUNNER_TEST_FAILURE_CODE,
])

struct DiagnosticPattern <: ConfigSection
    pattern::Union{Regex,String}
    match_by::String
    match_type::String
    severity::Int
    path::Maybe{Glob.FilenameMatch{String}}
end
@define_eq_overloads DiagnosticPattern

# Overload to inject custom validations for parsing `DiagnosticPattern` from
# `Configuration.to_dict(::DiagnosticConfig, config::AbstractDict{String})`
Base.convert(::Type{DiagnosticPattern}, x::AbstractDict{String}) =
    parse_diagnostic_pattern(x)

# N.B. `@option` automatically adds `Base.:(==)` overloads for annotated types,
# whose behavior is similar to those added by`@define_eq_overloads`

@option struct DiagnosticConfig <: ConfigSection
    enabled::Maybe{Bool}
    patterns::Maybe{Vector{DiagnosticPattern}}
end
default_config(::Type{DiagnosticConfig}) = DiagnosticConfig(true, DiagnosticPattern[])

@option struct JETLSConfig <: ConfigSection
    diagnostic::Maybe{DiagnosticConfig}
    full_analysis::Maybe{FullAnalysisConfig}
    testrunner::Maybe{TestRunnerConfig}
    formatter::Maybe{FormatterConfig}
end

const DEFAULT_CONFIG = JETLSConfig(
    diagnostic = default_config(DiagnosticConfig),
    full_analysis = default_config(FullAnalysisConfig),
    testrunner = default_config(TestRunnerConfig),
    formatter = default_config(FormatterConfig),
)

function get_default_config(path::Symbol...)
    config = getobjpath(DEFAULT_CONFIG, path...)
    @assert !isnothing(config) "Invalid default configuration values"
    return config
end

const EMPTY_CONFIG = JETLSConfig()

struct ConfigManagerData
    file_config::JETLSConfig
    lsp_config::JETLSConfig
    file_config_path::Union{Nothing,String}
    settings::JETLSConfig         # Current settings merged from two types of configuration
    filled_settings::JETLSConfig  # Current settings merged from two types of configuration, with `nothing` values filled with defaults
    initialized::Bool
    function ConfigManagerData(
            file_config::JETLSConfig,
            lsp_config::JETLSConfig,
            file_config_path::Union{Nothing,String},
            initialized::Bool
        )
        # Configuration priority:
        # 1. DEFAULT_CONFIG (base layer)
        # 2. LSP config via `workspace/configuration` (middle layer)
        # 3. File config from `.JETLSConfig.toml` (highest priority)
        #    - Allows client-agnostic configuration
        #    - Limited to project root scope only
        #    - Takes precedence since clients don't properly support
        #      hierarchical configuration via scopeUri
        settings = DEFAULT_CONFIG
        settings = merge_setting(settings, lsp_config)
        settings = merge_setting(settings, file_config)
        # Create setting structs without `nothing` values for use by `get_config`
        filled_settings = merge_setting(DEFAULT_CONFIG, settings)
        return new(file_config, lsp_config, file_config_path,
                   settings, filled_settings, initialized)
    end
end

ConfigManagerData() = ConfigManagerData(EMPTY_CONFIG, EMPTY_CONFIG, nothing, false)

function ConfigManagerData(
        data::ConfigManagerData;
        file_config::JETLSConfig = data.file_config,
        lsp_config::JETLSConfig = data.lsp_config,
        file_config_path::Union{Nothing,String} = data.file_config_path,
        initialized::Bool = data.initialized
    )
    return ConfigManagerData(file_config, lsp_config, file_config_path, initialized)
end

# Type aliases for document-synchronization caches using `SWContainer` (sequential-only updates)
const FileCache = SWContainer{Base.PersistentDict{URI,FileInfo}, SWStats}
const SavedFileCache = SWContainer{Base.PersistentDict{URI,SavedFileInfo}, SWStats}
const TestsetInfosCache = SWContainer{Base.PersistentDict{URI,TestsetInfos}, SWStats}

# Type aliases for concurrent updates using CASContainer (lightweight operations)
const ExtraDiagnostics = CASContainer{ExtraDiagnosticsData, CASStats}
const CurrentlyRequested = CASContainer{Base.PersistentDict{String,RequestCaller}, CASStats}
const CurrentlyRegistered = CASContainer{Set{Registered}, CASStats}
const CompletionResolverInfo = CASContainer{Union{Nothing,Tuple{Module,LSPostProcessor}}, CASStats}

# Type aliases for concurrent updates using LWContainer (non-retriable operations)
const ConfigManager = LWContainer{ConfigManagerData, LWStats}

const HandledHistory = FixedSizeFIFOQueue{Union{Int,String}}

mutable struct ServerState
    const file_cache::FileCache # syntactic analysis cache (synced with `textDocument/didChange`)
    const saved_file_cache::SavedFileCache # syntactic analysis cache (synced with `textDocument/didSave`)
    const testsetinfos_cache::TestsetInfosCache
    const analysis_manager::AnalysisManager
    const extra_diagnostics::ExtraDiagnostics
    const currently_handled::CurrentlyHandled
    const handled_history::HandledHistory
    const currently_requested::CurrentlyRequested
    const currently_registered::CurrentlyRegistered
    const config_manager::ConfigManager
    const completion_resolver_info::CompletionResolverInfo

    # Lifecycle fields (set after initialization request)
    encoding::PositionEncodingKind.Ty
    workspaceFolders::Vector{URI}
    root_path::String
    root_env_path::String
    init_params::InitializeParams
    function ServerState()
        return new(
            #=file_cache=# FileCache(Base.PersistentDict{URI,FileInfo}()),
            #=saved_file_cache=# SavedFileCache(Base.PersistentDict{URI,SavedFileInfo}()),
            #=testsetinfos_cache=# TestsetInfosCache(Base.PersistentDict{URI,TestsetInfos}()),
            #=analysis_manager=# AnalysisManager(#=n_workers=# 1), # TODO multiple workers
            #=extra_diagnostics=# ExtraDiagnostics(ExtraDiagnosticsData()),
            #=currently_handled=# CurrentlyHandled(),
            #=handled_history=# HandledHistory(128),
            #=currently_requested=# CurrentlyRequested(Base.PersistentDict{String,RequestCaller}()),
            #=currently_registered=# CurrentlyRegistered(Set{Registered}()),
            #=config_manager=# ConfigManager(ConfigManagerData()),
            #=completion_resolver_info=# CompletionResolverInfo(nothing),
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
Server() = Server(Returns(nothing), Endpoint(IOBuffer(), IOBuffer())) # used for tests
