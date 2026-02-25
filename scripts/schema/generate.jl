include("setup-schema-context.jl")
include("utils.jl")

const HELP_MSG = """
Usage: julia generate.jl TARGET FILE [--check]
Generates JSON Schema for JETLS configuration.

Arguments:
  TARGET            What schema to generate:
                      --config-toml     Complete schema for .JETLSConfig.toml
                      --settings        Settings schema
                      --init-options    Initialization options schema
  FILE              Path to output file (for generation) or file to check against (for --check)

Options:
  --check           Check if FILE matches the generated schema instead of writing to it
  --help            Show this help message
"""

const TARGETS = Dict(
    "--config-toml" => JETLS.JETLSConfig,
    "--settings" => JETLS.JETLSConfig,
    "--init-options" => JETLS.InitOptions
)

function parse_arguments(args::Vector{String})
    if "--help" in args
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
    gen_ctx = SchemaContext()
    setup_ctx!(gen_ctx)
    schema_dict = generate_schema_dict(target_arg, gen_ctx)

    if check_mode
        update_cmd = "julia --startup-file=no --project=scripts/schema scripts/schema/generate.jl $(target_arg) $(file_path)"
        check_json_file(file_path, schema_dict, update_cmd)
    else
        write_json_file(file_path, schema_dict, "Generated schema written to $file_path")
    end
end
