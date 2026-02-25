include("setup-schema-context.jl")
include("utils.jl")

const HELP_MSG = """
Usage: julia update-pkg-json.jl FILE [--check]
Generates VSCode configuration schema and updates package.json.

Arguments:
  FILE              Path to package.json file to update (or check against with --check)

Options:
  --check           Check if FILE matches the generated content instead of writing to it
  --help            Show this help message
"""

function parse_arguments(args::Vector{String})
    if "--help" in args
        println(HELP_MSG)
        exit(0)
    end

    check_mode, args_filtered = parse_check_flag(args)

    if length(args_filtered) != 1
        println("Error: FILE is required", stderr)
        println(HELP_MSG, stderr)
        exit(1)
    end

    file_path = args_filtered[1]
    if !check_mode && !isfile(file_path)
        println("Error: file not found at $file_path", stderr)
        exit(1)
    end

    return (file_path, check_mode)
end

function rename_description_to_markdown!(schema_dict::Dict)
    if haskey(schema_dict, "description")
        schema_dict["markdownDescription"] = schema_dict["description"]
        delete!(schema_dict, "description")
    end
    for v in values(schema_dict)
        if v isa Dict
            rename_description_to_markdown!(v)
        elseif v isa Vector
            for item in v
                if item isa Dict
                    rename_description_to_markdown!(item)
                end
            end
        end
    end
end

function generate_vscode_schemas(ctx::SchemaContext)
    expanded_schema = generate_schema(JETLS.JETLSConfig; ctx = ctx, inline_all_defs = true)
    rename_description_to_markdown!(expanded_schema.doc)

    init_options_schema = sort_keys(
        deepcopy(expanded_schema.doc["properties"]["initialization_options"])
    )
    delete!(expanded_schema.doc["properties"], "initialization_options")
    setting_schema = sort_keys(expanded_schema.doc["properties"])

    return (setting_schema, init_options_schema)
end

function update_package_json(
    package_json::AbstractDict,
    setting_schema::AbstractDict,
    init_options_schema::AbstractDict
)
    result = deepcopy(package_json)
    result["contributes"]["configuration"]["properties"]["jetls-client.settings"]["properties"] =
        setting_schema
    result["contributes"]["configuration"]["properties"]["jetls-client.initializationOptions"]["properties"] =
        init_options_schema
    return result
end

function (@main)(args::Vector{String})
    file_path, check_mode = parse_arguments(args)
    gen_ctx = SchemaContext()
    setup_ctx!(gen_ctx)

    setting_schema, init_options_schema = generate_vscode_schemas(gen_ctx)
    original_package_json = JSON.parsefile(file_path)
    updated_package_json = update_package_json(
        original_package_json,
        setting_schema,
        init_options_schema
    )

    if check_mode
        update_cmd = "julia --startup-file=no --project=scripts/schema scripts/schema/update-pkg-json.jl $(file_path)"
        check_json_file(file_path, updated_package_json, update_cmd)
    else
        write_json_file(file_path, updated_package_json, "Updated $file_path")
    end
end
