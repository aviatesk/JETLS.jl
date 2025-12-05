const DEFAULT_INIT_OPTIONS = InitOptions(; n_analysis_workers=1, module_overrides=ModuleOverride[])

function merge_init_options(base::InitOptions, overlay::InitOptions)
    InitOptions(;
        n_analysis_workers = something(overlay.n_analysis_workers, base.n_analysis_workers),
        module_overrides = something(overlay.module_overrides, base.module_overrides))
end

function validate_init_options(opts::InitOptions)
    n = opts.n_analysis_workers
    if n !== nothing && n < 1
        @warn "n_analysis_workers must be at least 1, using default" n
        return InitOptions(; n_analysis_workers=DEFAULT_INIT_OPTIONS.n_analysis_workers)
    end
    return opts
end

function parse_init_options(@nospecialize init_options)
    init_options === nothing && return DEFAULT_INIT_OPTIONS
    init_options isa AbstractDict || return DEFAULT_INIT_OPTIONS
    parsed = try
        validate_init_options(Configurations.from_dict(InitOptions, init_options))
    catch err
        @warn "Failed to parse initializationOptions, using defaults" err
        return DEFAULT_INIT_OPTIONS
    end
    return merge_init_options(DEFAULT_INIT_OPTIONS, parsed)
end

get_init_option(opts::InitOptions, key::Symbol) = @something getfield(opts, key) error(lazy"Invalid init option: $key")
