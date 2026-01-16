const SyntaxTree0 = typeof(JS.build_tree(JS.SyntaxTree, JS.parse!(JS.ParseStream(""))))

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

const EMPTY_TESTSETINFOS = TestsetInfo[]

# Primary file cache for document synchronization.
# Created on `textDocument/didOpen` and updated on `textDocument/didChange`.
# Contains the current editor state, including unsaved edits.
struct FileInfo
    version::Int
    parsed_stream::JS.ParseStream
    filename::String
    encoding::LSP.PositionEncodingKind.Ty
    testsetinfos::Vector{TestsetInfo}

    function FileInfo(
            version::Int, parsed_stream::JS.ParseStream, filename::AbstractString,
            encoding::LSP.PositionEncodingKind.Ty = LSP.PositionEncodingKind.UTF16,
            testsetinfos::Vector{TestsetInfo} = EMPTY_TESTSETINFOS
        )
        new(version, parsed_stream, filename, encoding, testsetinfos)
    end
end
@define_override_constructor FileInfo # For testsetinfos update

function FileInfo( # Constructor for production code (with URI)
        version::Int, parsed_stream::JS.ParseStream, uri::URI,
        encoding::LSP.PositionEncodingKind.Ty = LSP.PositionEncodingKind.UTF16,
        testsetinfos::Vector{TestsetInfo} = EMPTY_TESTSETINFOS
    )
    filename = uri2filename(uri)
    return FileInfo(version, parsed_stream, filename, encoding, testsetinfos)
end

function FileInfo( # Constructor for test code (with raw text input and filename)
        version::Int, s::Union{Vector{UInt8},AbstractString}, args...
    )
    return FileInfo(version, ParseStream!(s), args...)
end

# Secondary file cache representing on-disk state.
# Created on `textDocument/didOpen` and updated on `textDocument/didSave`.
# Used primarily for testrunner integration where consistency between on-disk state
# and editor state needs to be verified.
struct SavedFileInfo
    parsed_stream::JS.ParseStream
    syntax_node::JS.SyntaxNode
    encoding::LSP.PositionEncodingKind.Ty

    function SavedFileInfo(parsed_stream::JS.ParseStream, uri::URI, encoding::LSP.PositionEncodingKind.Ty)
        filename = uri2filename(uri)
        syntax_node = JS.build_tree(JS.SyntaxNode, parsed_stream; filename)
        new(parsed_stream, syntax_node, encoding)
    end
end

# Notebook document synchronization
# =================================

struct NotebookCellInfo
    uri::URI
    kind::LSP.NotebookCellKind.Ty
    text::String
end

struct CellRange
    cell_uri::URI
    line_offset::Int  # 0-based line offset in concatenated source
end

struct ConcatenatedNotebook
    source::String
    cell_ranges::Vector{CellRange}
end

struct NotebookInfo
    version::Int
    notebookType::String
    encoding::LSP.PositionEncodingKind.Ty
    cells::Vector{NotebookCellInfo}
    concat::ConcatenatedNotebook
end
@define_override_constructor NotebookInfo

abstract type AbstractCancelFlag end
function is_cancelled(::AbstractCancelFlag) end

"""
    CancelFlag

A thread-safe cancellation flag used to signal that an operation should be cancelled.

Cancellation can occur via two LSP mechanisms:
1. `\$/cancelRequest` - Client cancels a request by its message ID
2. `window/workDoneProgress/cancel` - Client cancels a server-initiated progress by its token

When either notification arrives, the corresponding `CancelFlag` in `server.state.currently_handled`
is looked up (by message ID or progress token) and `cancel!` is called on it.
Long-running operations should periodically check `is_cancelled(cancel_flag)` and abort if true.
"""
mutable struct CancelFlag <: AbstractCancelFlag
    @atomic cancelled::Bool
end
const DUMMY_CANCEL_FLAG = CancelFlag(false)

function cancel!(cancel_flag::CancelFlag)
    @atomic :release cancel_flag.cancelled = true
end

is_cancelled(cancel_flag::CancelFlag) = @atomic :acquire cancel_flag.cancelled

"""
    CombinedCancelFlag

Combines two `CancelFlag`s so that `is_cancelled` returns true if either flag is cancelled.

This is used for server-initiated progress where cancellation can come from two sources:
- `flag1`: The original request's cancel flag (cancelled via `\$/cancelRequest`)
- `flag2`: The progress token's cancel flag (cancelled via `window/workDoneProgress/cancel`)

When using server-initiated progress, the original request's `CancelFlag` is stored in the
`RequestCaller` struct. When the progress response arrives, a `CombinedCancelFlag` is created
to check both the original request cancellation and the progress UI cancellation.
"""
struct CombinedCancelFlag <: AbstractCancelFlag
    flag1::CancelFlag
    flag2::CancelFlag
end
is_cancelled(cf::CombinedCancelFlag) = is_cancelled(cf.flag1) || is_cancelled(cf.flag2)

struct CancellableToken
    token::ProgressToken
    cancel_flag::CancelFlag
end

const CurrentlyHandled = Dict{MessageId, CancelFlag}

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
    module_context::Union{Nothing,Module}
    OutOfScope() = new(nothing) # really unknown context
    OutOfScope(module_context::Module) = new(module_context)
end

# TODO support multiple analysis units, which can happen if this file is included from multiple different analysis_units
const AnalysisInfo = Union{AnalysisResult,OutOfScope}

struct AnalysisRequest
    entry::AnalysisEntry
    uri::URI
    generation::Int
    cancellable_token::Union{Nothing,CancellableToken}
    notify_diagnostics::Bool
    prev_analysis_result::Union{Nothing,AnalysisResult}
    completion::Base.Event
    function AnalysisRequest(
            entry::AnalysisEntry,
            uri::URI,
            generation::Int,
            cancellable_token::Union{Nothing,CancellableToken},
            notify_diagnostics::Bool,
            prev_analysis_result::Union{Nothing,AnalysisResult},
            completion::Base.Event = Base.Event()
        )
        return new(entry, uri, generation, cancellable_token, notify_diagnostics, prev_analysis_result, completion)
    end
end

const AnalysisCache = LWContainer{Dict{URI,AnalysisInfo}, LWStats}
const PendingAnalyses = CASContainer{Dict{AnalysisEntry,Union{Nothing,AnalysisRequest}}, CASStats}
const CurrentGenerations = CASContainer{Dict{AnalysisEntry,Int}}
const AnalyzedGenerations = CASContainer{Dict{AnalysisEntry,Int}}
const DebouncedRequests = LWContainer{Dict{AnalysisEntry,Tuple{Timer,Base.Event}}, LWStats}
const InstantiatedEnvs = LWContainer{Dict{String,Union{Nothing,Tuple{Base.PkgId,String}}}}

struct AnalysisManager
    cache::AnalysisCache
    pending_analyses::PendingAnalyses
    queue::Channel{AnalysisRequest}
    current_generations::CurrentGenerations
    analyzed_generations::AnalyzedGenerations
    debounced::DebouncedRequests
    instantiated_envs::InstantiatedEnvs
    function AnalysisManager()
        return new(
            AnalysisCache(Dict{URI,AnalysisInfo}()),
            PendingAnalyses(Dict{AnalysisEntry,Union{Nothing,AnalysisRequest}}()),
            Channel{AnalysisRequest}(Inf),
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

For `ConfigSection` subtypes that appear in `Vector` fields, you must implement
`merge_key(::Type{NewConfig}) -> Symbol`, which returns a field name to use as key when
merging vectors. Elements with matching keys are merged together; others are preserved or added.

Finally, add the new config section to `JETLSConfig` struct below.
"""
abstract type ConfigSection end

function merge_key end

@option struct FullAnalysisConfig <: ConfigSection
    debounce::Maybe{Float64}
    auto_instantiate::Maybe{Bool}
end

@option struct TestRunnerConfig <: ConfigSection
    executable::Maybe{String}
end

@option "custom" struct CustomFormatterConfig
    executable::Maybe{String}
    executable_range::Maybe{String}
end

const FormatterConfig = Union{String,CustomFormatterConfig}

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
const LOWERING_UNDEF_GLOBAL_VAR_CODE = "lowering/undef-global-var"
const LOWERING_CAPTURED_BOXED_VARIABLE_CODE = "lowering/captured-boxed-variable"
const TOPLEVEL_ERROR_CODE = "toplevel/error"
const TOPLEVEL_METHOD_OVERWRITE_CODE = "toplevel/method-overwrite"
const TOPLEVEL_ABSTRACT_FIELD_CODE = "toplevel/abstract-field"
const INFERENCE_UNDEF_GLOBAL_VAR_CODE = "inference/undef-global-var"
const INFERENCE_UNDEF_LOCAL_VAR_CODE = "inference/undef-local-var"
const INFERENCE_UNDEF_STATIC_PARAM_CODE = "inference/undef-static-param" # currently not reported
const INFERENCE_FIELD_ERROR_CODE = "inference/field-error"
const INFERENCE_BOUNDS_ERROR_CODE = "inference/bounds-error"
const TESTRUNNER_TEST_FAILURE_CODE = "testrunner/test-failure"

const ALL_DIAGNOSTIC_CODES = Set{String}(String[
    SYNTAX_DIAGNOSTIC_CODE,
    LOWERING_UNUSED_ARGUMENT_CODE,
    LOWERING_UNUSED_LOCAL_CODE,
    LOWERING_ERROR_CODE,
    LOWERING_MACRO_EXPANSION_ERROR_CODE,
    LOWERING_UNDEF_GLOBAL_VAR_CODE,
    LOWERING_CAPTURED_BOXED_VARIABLE_CODE,
    TOPLEVEL_ERROR_CODE,
    TOPLEVEL_METHOD_OVERWRITE_CODE,
    TOPLEVEL_ABSTRACT_FIELD_CODE,
    INFERENCE_UNDEF_GLOBAL_VAR_CODE,
    INFERENCE_UNDEF_LOCAL_VAR_CODE,
    INFERENCE_UNDEF_STATIC_PARAM_CODE,
    INFERENCE_FIELD_ERROR_CODE,
    INFERENCE_BOUNDS_ERROR_CODE,
    TESTRUNNER_TEST_FAILURE_CODE,
])

struct DiagnosticPattern <: ConfigSection
    pattern::Union{Regex,String}
    match_by::String
    match_type::String
    severity::Int
    path::Maybe{Glob.FilenameMatch{String}}
    __pattern_value__::String # used for updated setting tracking
end
@define_eq_overloads DiagnosticPattern

# Overload to inject custom validations for parsing `DiagnosticPattern` from
# `Configuration.to_dict(::DiagnosticConfig, config::AbstractDict{String})`
Base.convert(::Type{DiagnosticPattern}, x::AbstractDict{String}) =
    parse_diagnostic_pattern(x)

merge_key(::Type{DiagnosticPattern}) = :__pattern_value__

# N.B. `@option` automatically adds `Base.:(==)` overloads for annotated types,
# whose behavior is similar to those added by`@define_eq_overloads`

@option struct DiagnosticConfig <: ConfigSection
    enabled::Maybe{Bool}
    patterns::Maybe{Vector{DiagnosticPattern}}
    allow_unused_underscore::Maybe{Bool}
end

# Internal, undocumented configuration for full-analysis module overrides.
struct AnalysisOverride <: ConfigSection
    path::Glob.FilenameMatch{String}
    module_name::Maybe{String}
end
@define_eq_overloads AnalysisOverride
Base.convert(::Type{AnalysisOverride}, x::AbstractDict{String}) = parse_analysis_override(x)
merge_key(::Type{AnalysisOverride}) = :path

# Static initialization options from `InitializeParams.initializationOptions`.
# These are set once during the initialize request and remain constant.
@option struct InitOptions <: ConfigSection
    n_analysis_workers::Maybe{Int}
    analysis_overrides::Maybe{Vector{AnalysisOverride}}
end
function Base.show(io::IO, init_options::InitOptions)
    print(io, "InitOptions(;")
    n_analysis_workers = init_options.n_analysis_workers
    n_analysis_workers === nothing || print(io, " n_analysis_workers=", n_analysis_workers)
    analysis_overrides = init_options.analysis_overrides
    analysis_overrides === nothing || print(io, " analysis_overrides=", analysis_overrides)
    print(io, ")")
end
const DEFAULT_INIT_OPTIONS = InitOptions(; n_analysis_workers=1, analysis_overrides=AnalysisOverride[])

@option struct LaTeXEmojiConfig <: ConfigSection
    strip_prefix::Maybe{Union{Missing,Bool}} # missing is used as sentinel for default setting value
end

@option struct MethodSignatureConfig <: ConfigSection
    prepend_inference_result::Maybe{Union{Missing,Bool}} # missing is used as sentinel for default setting value
end

@option struct CompletionConfig <: ConfigSection
    latex_emoji::Maybe{LaTeXEmojiConfig}
    method_signature::Maybe{MethodSignatureConfig}
end

@option struct JETLSConfig <: ConfigSection
    diagnostic::Maybe{DiagnosticConfig}
    full_analysis::Maybe{FullAnalysisConfig}
    testrunner::Maybe{TestRunnerConfig}
    formatter::Maybe{FormatterConfig}
    completion::Maybe{CompletionConfig}
    # This initialization options are read once at the server initialization and held in
    # `server.state.init_options`, so it might seem strange to hold them here also,
    # but they need to be set here for cases where initialization options are set in
    # .JETLSConfig.toml.
    initialization_options::Maybe{InitOptions}
end

const DEFAULT_CONFIG = JETLSConfig(;
    diagnostic = DiagnosticConfig(true, DiagnosticPattern[], true),
    full_analysis = FullAnalysisConfig(1.0, true),
    testrunner = TestRunnerConfig(@static Sys.iswindows() ? "testrunner.bat" : "testrunner"),
    formatter = "Runic",
    completion = CompletionConfig(LaTeXEmojiConfig(missing), MethodSignatureConfig(missing)),
    initialization_options = DEFAULT_INIT_OPTIONS)

function get_default_config(path::Symbol...)
    if length(path) ≥ 1
        @assert first(path) !== :initialization_options "Do not use `JETLSConfig` to get initialization options"
    end
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
        settings = merge_settings(settings, lsp_config)
        settings = merge_settings(settings, file_config)
        # Create setting structs without `nothing` values for use by `get_config`
        filled_settings = merge_settings(DEFAULT_CONFIG, settings)
        return new(file_config, lsp_config, file_config_path,
                   settings, filled_settings, initialized)
    end
end

ConfigManagerData() = ConfigManagerData(EMPTY_CONFIG, EMPTY_CONFIG, nothing, false)

# N.B. Can't use `@define_override_constructor` since the main constructor doesn't take all the fields
function ConfigManagerData(
        data::ConfigManagerData;
        file_config::JETLSConfig = data.file_config,
        lsp_config::JETLSConfig = data.lsp_config,
        file_config_path::Union{Nothing,String} = data.file_config_path,
        initialized::Bool = data.initialized
    )
    return ConfigManagerData(file_config, lsp_config, file_config_path, initialized)
end

struct BindingOccurrence{Tree3<:JS.SyntaxTree}
    tree::Tree3
    kind::Symbol
end

# Types for binding occurrences cache.
# IMPORTANT: We must not cache full `JS.SyntaxTree` or `JL.BindingInfo` objects
# as they hold references to large internal structures (syntax graphs, lowering
# contexts). Instead, we extract only the essential information needed for
# LSP features, i.e. mainly binding kind and location information.

struct BindingInfoKey
    mod::Union{Nothing,Module}
    name::String
    BindingInfoKey(binfo::JL.BindingInfo) = new(binfo.mod, binfo.name)
end

"""
    CachedSyntaxTree

A lightweight representation of syntax tree location information.
This struct stores only the byte range and source location, implementing the
minimum `JS.SyntaxTree` API (`first_byte`, `last_byte`, `source_location`)
required by [`jsobj_to_range`](@ref) that convert syntax tree to LSP `Range` objects.
"""
struct CachedSyntaxTree
    fb::Int
    lb::Int
    line::Int
    column::Int
    function CachedSyntaxTree(st::JS.SyntaxTree)
        return new(JS.first_byte(st), JS.last_byte(st), JS.source_location(st)...)
    end
end
JS.first_byte(cst::CachedSyntaxTree) = cst.fb
JS.last_byte(cst::CachedSyntaxTree) = cst.lb
JS.source_location(cst::CachedSyntaxTree) = (cst.line, cst.column)

struct CachedBindingOccurrence
    tree::CachedSyntaxTree
    kind::Symbol
    function CachedBindingOccurrence(occurrence::BindingOccurrence)
        return new(CachedSyntaxTree(occurrence.tree), occurrence.kind)
    end
end

const BindingOccurrencesRangeKey = UnitRange{Int}
const BindingOccurrencesResult = Dict{BindingInfoKey,Set{CachedBindingOccurrence}}
const BindingOccurrencesCacheEntry = Base.PersistentDict{BindingOccurrencesRangeKey,BindingOccurrencesResult}

const AnyBindingOccurrence = Union{BindingOccurrence,CachedBindingOccurrence}

struct GlobalCompletionResolverInfo
    id::String
    mod::Module
    postprocessor::LSPostProcessor
end

struct MethodSignatureCompletionResolverInfo
    id::String
    matches::CC.MethodLookupResult
    postprocessor::LSPostProcessor
end

# Type aliases for document-synchronization caches using `SWContainer` (sequential-only updates)
const FileCache = SWContainer{Base.PersistentDict{URI,FileInfo}, SWStats}
const SavedFileCache = SWContainer{Base.PersistentDict{URI,SavedFileInfo}, SWStats}
const NotebookCache = SWContainer{Base.PersistentDict{URI,NotebookInfo}, SWStats}
const CellToNotebookMap = SWContainer{Base.PersistentDict{URI,URI}, SWStats} # cell URI -> notebook URI

# Type aliases for concurrent updates using CASContainer (lightweight operations)
const ExtraDiagnostics = CASContainer{ExtraDiagnosticsData, CASStats}
const CurrentlyRequested = CASContainer{Base.PersistentDict{String,RequestCaller}, CASStats}
const CurrentlyRegistered = CASContainer{Set{Registered}, CASStats}
const CompletionResolverInfo = CASContainer{Union{Nothing,GlobalCompletionResolverInfo,MethodSignatureCompletionResolverInfo}, CASStats}

# Type aliases for concurrent updates using LWContainer
const DocumentSymbolCacheData = Base.PersistentDict{URI,Vector{DocumentSymbol}}
const DocumentSymbolCache = LWContainer{DocumentSymbolCacheData, LWStats}
const BindingOccurrencesCacheData = Base.PersistentDict{URI,BindingOccurrencesCacheEntry}
const BindingOccurrencesCache = LWContainer{BindingOccurrencesCacheData, LWStats}
const ConfigManager = LWContainer{ConfigManagerData, LWStats}

const HandledHistory = FixedSizeFIFOQueue{MessageId}

struct HandledToken
    id::MessageId
end

mutable struct ServerState
    const file_cache::FileCache # syntactic analysis cache (synced with `textDocument/didChange`)
    const saved_file_cache::SavedFileCache # syntactic analysis cache (synced with `textDocument/didSave`)
    const notebook_cache::NotebookCache # notebook document cache (synced with `notebookDocument/did*`), mapping notebook URIs to their notebook info
    const cell_to_notebook::CellToNotebookMap # maps cell URIs to their notebook URI
    # Document symbol cache for both synced and unsynced files.
    # Uses LWContainer for concurrent writes from:
    # - `get_document_symbols!` (on cache miss)
    # - `textDocument/didChange` (invalidates synced files)
    # - `workspace/didChangeWatchedFiles` (invalidates unsynced files)
    const document_symbol_cache::DocumentSymbolCache
    # Binding occurrences cache for global binding analysis (references, rename).
    # Same invalidation pattern as document_symbol_cache.
    # TODO: This cache uses analysis context (module context from full-analysis).
    # It should also be invalidated when full-analysis updates module context,
    # but that is not yet implemented.
    const binding_occurrences_cache::BindingOccurrencesCache
    const analysis_manager::AnalysisManager
    const extra_diagnostics::ExtraDiagnostics
    const currently_handled::CurrentlyHandled
    const handled_history::HandledHistory
    const currently_requested::CurrentlyRequested
    const currently_registered::CurrentlyRegistered
    const config_manager::ConfigManager
    const completion_resolver_info::CompletionResolverInfo
    const suppress_notifications::Bool

    # Lifecycle fields (set after initialization request)
    encoding::PositionEncodingKind.Ty
    init_options::InitOptions
    workspaceFolders::Vector{URI}
    root_path::String
    root_env_path::String
    init_params::InitializeParams
    function ServerState(; suppress_notifications::Bool=false)
        return new(
            #=file_cache=# FileCache(Base.PersistentDict{URI,FileInfo}()),
            #=saved_file_cache=# SavedFileCache(Base.PersistentDict{URI,SavedFileInfo}()),
            #=notebook_cache=# NotebookCache(Base.PersistentDict{URI,NotebookInfo}()),
            #=cell_to_notebook=# CellToNotebookMap(Base.PersistentDict{URI,URI}()),
            #=document_symbol_cache=# DocumentSymbolCache(DocumentSymbolCacheData()),
            #=binding_occurrences_cache=# BindingOccurrencesCache(BindingOccurrencesCacheData()),
            #=analysis_manager=# AnalysisManager(),
            #=extra_diagnostics=# ExtraDiagnostics(ExtraDiagnosticsData()),
            #=currently_handled=# CurrentlyHandled(),
            #=handled_history=# HandledHistory(128),
            #=currently_requested=# CurrentlyRequested(Base.PersistentDict{String,RequestCaller}()),
            #=currently_registered=# CurrentlyRegistered(Set{Registered}()),
            #=config_manager=# ConfigManager(ConfigManagerData()),
            #=completion_resolver_info=# CompletionResolverInfo(nothing),
            suppress_notifications,
            #=encoding=# PositionEncodingKind.UTF16, # initialize with UTF16 (for tests)
            #=init_options=# DEFAULT_INIT_OPTIONS, # initialize with defaults
        )
    end
end

struct Server{Callback}
    endpoint::Endpoint
    callback::Callback
    state::ServerState
    message_queue::Channel{Any}
    function Server(callback::Callback, endpoint::Endpoint; suppress_notifications::Bool=false) where Callback
        return new{Callback}(
            endpoint,
            callback,
            ServerState(; suppress_notifications),
            Channel{Any}(Inf))
    end
end
Server(; suppress_notifications::Bool=true) = # used for tests
    Server(Returns(nothing), Endpoint(IOBuffer(), IOBuffer()); suppress_notifications)
