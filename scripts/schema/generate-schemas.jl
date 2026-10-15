const HELP_MSG = """
Usage: julia --project=scripts/schema scripts/schema/generate-schemas.jl [OPTIONS] TARGET FILE

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
  --check           Verify that FILE matches the generated schema
"""

using TOML
using JETLSCore, JETLSCore.Glob
using Struct2JSONSchema
using JSON
using OrderedCollections

function sort_keys(d::AbstractDict)
    return OrderedDict{String, Any}(
        k => sort_keys(d[k]) for k in sort(collect(keys(d)))
    )
end
sort_keys(v::Vector) = map(sort_keys, v)
sort_keys(x) = x

function attach_description!(ctx::SchemaContext, desc_path)
    desc = TOML.parsefile(joinpath(@__DIR__, desc_path))

    for (struct_name, fields) in desc
        struct_sym = Symbol(struct_name)
        if !isdefined(JETLSCore, struct_sym)
            error("Struct '$struct_name' not found in JETLSCore module (from description.toml)")
        end
        struct_type = getproperty(JETLSCore, struct_sym)

        struct_fieldnames = fieldnames(struct_type)
        for (field_name, field_desc) in fields
            field_sym = Symbol(field_name)
            if field_sym ∉ struct_fieldnames
                error(
                    "Field '$field_name' not found in struct '$struct_name' " *
                        "(from description.toml). Available fields: $(struct_fieldnames)"
                )
            end
            describe!(ctx, struct_type, field_sym, field_desc)
        end
    end
    return desc
end

const description_toml = joinpath(dirname(dirname(@__DIR__)), "schemas", "description.toml")

function setup_ctx!(ctx::SchemaContext)
    auto_optional_nothing!(ctx)
    desc = attach_description!(ctx, description_toml)
    defaultvalue!(ctx, JETLSCore.DEFAULT_CONFIG)

    # `__pattern_value__` is an internal field and not appeared in the config file
    skip!(ctx, JETLSCore.DiagnosticPattern, :__pattern_value__)

    skip!(ctx, JETLSCore.ConcretizationPattern, :__pattern_value__)
    override_field!(ctx, JETLSCore.ConcretizationPattern, :pattern) do _
        # JSON Schema regex requiring at least one non-whitespace character.
        Dict("type" => "string", "pattern" => raw"\S")
    end

    override_field!(ctx, JETLSCore.FullAnalysisConfig, :auto_instantiate) do _
        Dict("type" => "string", "enum" => collect(JETLSCore.AUTO_INSTANTIATE_VALUES))
    end

    override_field!(ctx, JETLSCore.FullAnalysisConfig, :concretization_timeout) do _
        Dict(
            "oneOf" => [
                Dict("type" => "number", "exclusiveMinimum" => 0),
                Dict("type" => "string", "enum" => ["inf"]),
            ]
        )
    end

    override_field!(ctx, JETLSCore.TestRunnerConfig, :env) do _
        Dict(
            "type" => "object",
            "additionalProperties" => Dict("type" => "string"),
            "propertyNames" => Dict(
                "not" => Dict("enum" => collect(JETLSCore.TESTRUNNER_RESERVED_ENV_KEYS))),
        )
    end

    override_field!(ctx, JETLSCore.DiagnosticPattern, :match_by) do _
        Dict("type" => "string", "enum" => ["code", "message"])
    end

    override_field!(ctx, JETLSCore.DiagnosticPattern, :match_type) do _
        Dict("type" => "string", "enum" => ["literal", "regex"])
    end

    override_field!(ctx, JETLSCore.DiagnosticPattern, :severity) do _
        Dict(
            "oneOf" => [
                Dict("type" => "integer", "minimum" => 0, "maximum" => 4),
                Dict("type" => "string", "enum" => ["off", "error", "warning", "warn", "information", "info", "hint"]),
            ]
        )
    end

    # path is Glob.FilenameMatch internally, but in config file, it justs a string
    override_type!(ctx, Glob.FilenameMatch{String}) do _
        Dict("type" => "string")
    end

    optional!(ctx, JETLSCore.AnalysisOverride, :on_include)
    override_field!(ctx, JETLSCore.AnalysisOverride, :on_include) do _
        Dict(
            "type" => "string",
            "enum" => ["stop", "skip"],
            "default" => "stop",
            "description" => desc["AnalysisOverride"]["on_include"])
    end

    optional!(ctx, JETLSCore.AnalysisOverride, :full_analysis)
    override_field!(ctx, JETLSCore.AnalysisOverride, :full_analysis) do _
        Dict(
            "type" => "boolean",
            "default" => false,
            "description" => desc["AnalysisOverride"]["full_analysis"])
    end

    optional!(ctx, JETLSCore.JETLSConfig, :formatter)

    # Unlike the struct definition, the actual config file requires a "custom" nesting
    # for dict-to-struct mapping purposes. The formatter can be specified as:
    # formatter = "JuliaFormatter" or
    # formatter = "Runic" or
    # [formatter.custom]
    # executable = "/path/to/formatter"
    # executable_range = "/path/to/range_formatters"
    # This nesting does not appear in the struct structure, and
    # it is most straightforward to just define the schema for it manually
    override_field!(ctx, JETLSCore.JETLSConfig, :formatter) do _
        Dict(
            "oneOf" => [
                Dict("type" => "string", "enum" => ["Runic", "JuliaFormatter"]),
                Dict(
                    "type" => "object",
                    "properties" => Dict(
                        "custom" => Dict(
                            "type" => "object",
                            "properties" => Dict(
                                "executable" => Dict(
                                    "type" => "string",
                                    "description" => desc["CustomFormatterConfig"]["executable"]
                                ),
                                "executable_range" => Dict(
                                    "type" => "string",
                                    "description" => desc["CustomFormatterConfig"]["executable_range"]
                                )
                            ),
                            "required" => ["executable"],
                            "additionalProperties" => false
                        )
                    ),
                    "required" => ["custom"],
                    "additionalProperties" => false
                ),
            ],
        )
    end

    return ctx
end

update_msg(file_path::String, update_command::String) =
    """Error: $file_path is out of date
    Run the following command to update it:
      $update_command
    """

function check_json_file(file_path::String, expected::AbstractDict, update_command::String)
    if !isfile(file_path)
        println(stderr, "Error: file not found at $file_path")
        return 1
    end
    existing = JSON.parsefile(file_path)
    if expected != existing
        print(stderr, update_msg(file_path, update_command))
        return 1
    end
    println("$file_path is up to date")
    return 0
end

function write_json_file(file_path::String, content::AbstractDict, success_msg::String)
    open(file_path, "w") do io
        println(io, JSON.json(content, 2))
    end
    return println(success_msg)
end

function parse_check_flag(args::Vector{String})
    check_mode = "--check" in args
    args_filtered = filter(arg -> arg != "--check", args)
    return (check_mode, args_filtered)
end

# VSCode configuration fragments spliced into the extension's `package.json`:
# the `jetls-client.settings` properties map and the
# `jetls-client.initializationOptions` property schema.
# Also published on releases as the `vscode-configuration.json` asset,
# which the extension repository syncs its `package.json` from.

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
    expanded_schema = generate_schema(JETLSCore.JETLSConfig; ctx = ctx, inline_all_defs = true)
    rename_description_to_markdown!(expanded_schema.doc)

    init_options_schema = deepcopy(expanded_schema.doc["properties"]["initialization_options"])
    # internal options for JETLS development, which `settings.json` should not suggest
    analysis_override_schema = init_options_schema["properties"]["analysis_overrides"]["items"]
    for name in ("module_name", "full_analysis")
        analysis_override_schema["properties"][name]["doNotSuggest"] = true
    end
    init_options_schema = sort_keys(init_options_schema)
    delete!(expanded_schema.doc["properties"], "initialization_options")
    setting_schema = sort_keys(expanded_schema.doc["properties"])

    return (setting_schema, init_options_schema)
end

const TARGETS = Dict(
        "--config-toml" => JETLSCore.JETLSConfig,
        "--settings" => JETLSCore.JETLSConfig,
        "--init-options" => JETLSCore.InitOptions,
        "--vscode-configuration" => JETLSCore.JETLSConfig,
    )

function parse_arguments(args::Vector{String})
    if "-h" in args || "--help" in args
        print(HELP_MSG)
        return 0
    end

    check_mode, args_filtered = parse_check_flag(args)

    if length(args_filtered) != 2
        println(stderr, "Error: TARGET and FILE are required")
        print(stderr, HELP_MSG)
        return 1
    end

    target_arg, file_path = args_filtered
    if !haskey(TARGETS, target_arg)
        println(stderr, "Error: Unknown target: $(target_arg)")
        print(stderr, HELP_MSG)
        return 1
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
        skip!(ctx, JETLSCore.JETLSConfig, :initialization_options)
    end
    # Inline all $defs/$ref for config-toml schema so that TOML language servers
    # (e.g. Tombi) that don't support $ref resolution can still use it
    inline_all_defs = target_arg == "--config-toml"
    schema = generate_schema(target; ctx, inline_all_defs)
    return sort_keys(schema.doc)
end

function (@main)(args::Vector{String})
    parsed = parse_arguments(args)
    parsed isa Int && return parsed
    target_arg, file_path, check_mode = parsed
    gen_ctx = SchemaContext(; javascript_safe_numbers = true)
    setup_ctx!(gen_ctx)
    schema_dict = generate_schema_dict(target_arg, gen_ctx)

    if check_mode
        update_cmd = "julia --startup-file=no --project=scripts/schema scripts/schema/generate-schemas.jl $(target_arg) $(file_path)"
        return check_json_file(file_path, schema_dict, update_cmd)
    else
        write_json_file(file_path, schema_dict, "Generated schema written to $file_path")
        return 0
    end
end
@doc HELP_MSG main
