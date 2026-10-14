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
