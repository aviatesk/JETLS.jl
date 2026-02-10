function merge_init_options(base::InitOptions, overlay::InitOptions)
    merge_and_track(Returns(nothing), base, overlay, ())
end

function validate_init_options(server::Server, opts::InitOptions)
    n = opts.n_analysis_workers
    if n !== nothing && n < 1
        show_warning_message(server,
            "`n_analysis_workers` must be at least 1 (got $n), using default")
        return InitOptions(; n_analysis_workers=DEFAULT_INIT_OPTIONS.n_analysis_workers)
    end
    return opts
end

function parse_init_options(server::Server, @nospecialize init_options)
    init_options === nothing && return DEFAULT_INIT_OPTIONS
    init_options isa AbstractDict || return DEFAULT_INIT_OPTIONS
    parsed = try
        validate_init_options(server, Configurations.from_dict(InitOptions, init_options))
    catch err
        show_warning_message(server,
            "Failed to parse initializationOptions, using defaults: $err")
        @error "Failed to parse initializationOptions, using defaults"
        Base.showerror(stderr, err, catch_backtrace())
        return DEFAULT_INIT_OPTIONS
    end
    return merge_init_options(DEFAULT_INIT_OPTIONS, parsed)
end

get_init_option(opts::InitOptions, key::Symbol) = @something getfield(opts, key) error(lazy"Invalid init option: $key")

function load_file_init_options(server::Server, filepath::AbstractString)
    isfile(filepath) || return nothing
    parsed = TOML.tryparsefile(filepath)
    if parsed isa TOML.ParserError
        show_error_message(server,
            "Failed to parse .JETLSConfig.toml file at $filepath: $(sprint(Base.showerror, parsed))")
        @error "Failed to parse .JETLSConfig.toml file" filepath
        Base.showerror(stderr, parsed)
        return nothing
    end
    init_options_dict = get(parsed, "initialization_options", nothing)
    init_options_dict === nothing && return nothing
    if !(init_options_dict isa AbstractDict)
        show_error_message(server,
            "Invalid `[initialization_options]` in $filepath: expected a table, but got $(typeof(init_options_dict))")
        return nothing
    end
    try
        return validate_init_options(server, Configurations.from_dict(InitOptions, init_options_dict))
    catch err
        show_error_message(server,
            "Failed to parse `[initialization_options]` in $filepath: $err")
        return nothing
    end
end

function load_file_init_options!(server::Server, filepath::AbstractString)
    server.state.init_options = merge_init_options(server.state.init_options,
        @something load_file_init_options(server, filepath) return nothing)
end
