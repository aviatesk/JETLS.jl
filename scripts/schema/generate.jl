include("setup-schema-context.jl")
include("utils.jl")
include("vscode-schemas.jl")

const HELP_MSG = """
Usage: julia --project=scripts/schema scripts/schema/generate.jl
       [OPTIONS] TARGET FILE

Generate a JSON Schema for JETLS configuration.

Arguments:
  TARGET            Schema to generate:
                      --config-toml   Complete .JETLSConfig.toml schema
                      --settings      Settings schema
                      --init-options  Initialization options schema
                      --vscode-configuration
                                      VSCode package.json configuration fragments
  FILE              Output file, or file to verify when using --check

Options:
  -h, --help        Show this help message and exit
  --check           Verify that FILE matches the generated schema"""

const TARGETS = Dict(
    "--config-toml" => JETLS.JETLSConfig,
    "--settings" => JETLS.JETLSConfig,
    "--init-options" => JETLS.InitOptions,
    "--vscode-configuration" => JETLS.JETLSConfig
)

function parse_arguments(args::Vector{String})
    if "-h" in args || "--help" in args
        println(HELP_MSG)
        exit(0)
    end

    check_mode, args_filtered = parse_check_flag(args)

    if length(args_filtered) != 2
        println("Error: TARGET and FILE are required", stderr)
        println(HELP_MSG, stderr)
        exit(1)
    end

    target_arg, file_path = args_filtered
    if !haskey(TARGETS, target_arg)
        println("Error: Unknown target: $(target_arg)", stderr)
        println(HELP_MSG, stderr)
        exit(1)
    end

    return (target_arg, file_path, check_mode)
end

function generate_schema_dict(target_arg::String, ctx::SchemaContext)
    if target_arg == "--vscode-configuration"
        setting_schema, init_options_schema = generate_vscode_schemas(ctx)
        return sort_keys(Dict{String, Any}(
            "settings" => setting_schema,
            "initializationOptions" => init_options_schema
        ))
    end
    target = TARGETS[target_arg]
    if target_arg == "--settings"
        skip!(ctx, JETLS.JETLSConfig, :initialization_options)
    end
    # Inline all $defs/$ref for config-toml schema so that TOML language servers
    # (e.g. Tombi) that don't support $ref resolution can still use it
    inline_all_defs = target_arg == "--config-toml"
    schema = generate_schema(target; ctx, inline_all_defs)
    return sort_keys(schema.doc)
end

function (@main)(args::Vector{String})
    target_arg, file_path, check_mode = parse_arguments(args)
    gen_ctx = SchemaContext(; javascript_safe_numbers = true)
    setup_ctx!(gen_ctx)
    schema_dict = generate_schema_dict(target_arg, gen_ctx)

    if check_mode
        update_cmd = "julia --startup-file=no --project=scripts/schema scripts/schema/generate.jl $(target_arg) $(file_path)"
        check_json_file(file_path, schema_dict, update_cmd)
    else
        write_json_file(file_path, schema_dict, "Generated schema written to $file_path")
    end
end
