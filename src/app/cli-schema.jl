const schema_help_message = """
    jetls schema - Print JSON schema for JETLS configuration

    Usage: jetls schema [--settings | --init-options | --config-toml]

    Options:
      --settings        Print the workspace settings schema
      --init-options    Print the initialization options schema
      --config-toml     Print the .jetls.toml configuration schema
      --help, -h        Show this help message
    """

function run_schema(args::Vector{String}, out::IO=stdout)
    if isempty(args) || args[1] in ("-h", "--help", "help")
        print(out, schema_help_message)
        return 0
    end

    schema_map = Dict(
        "--settings"     => "settings.schema.json",
        "--init-options" => "init-options.schema.json",
        "--config-toml"  => "config-toml.schema.json",
    )

    schema_dir = joinpath(dirname(dirname(@__DIR__)), "schemas")
    for arg in args
        filename = get(schema_map, arg, nothing)
        if isnothing(filename)
            @error "Unknown schema option" arg
            print(stderr, schema_help_message)
            return 1
        end
        path = joinpath(schema_dir, filename)
        print(out, read(path, String))
    end
    return 0
end
