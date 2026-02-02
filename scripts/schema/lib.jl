using TOML
using JETLS
using Struct2JSONSchema
using JSON
using Glob


function attach_description(ctx::SchemaContext, desc_path)
    desc = TOML.parsefile(joinpath(@__DIR__, desc_path))

    for (struct_name, fields) in desc
        struct_sym = Symbol(struct_name)
        if !isdefined(JETLS, struct_sym)
            error("Struct '$struct_name' not found in JETLS module (from description.toml)")
        end
        struct_type = getproperty(JETLS, struct_sym)

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
end

function setup_ctx!(ctx::SchemaContext)
    auto_optional_nothing!(ctx)
    attach_description(ctx, "description.toml")
    defaultvalue!(ctx, JETLS.DEFAULT_CONFIG)

    # `__pattern_value__` is an internal field and not appeared in the config file
    skip!(ctx, JETLS.DiagnosticPattern, :__pattern_value__)

    override_field!(ctx, JETLS.DiagnosticPattern, :match_by) do _
        Dict("type" => "string", "enum" => ["code", "message"])
    end

    override_field!(ctx, JETLS.DiagnosticPattern, :match_type) do _
        Dict("type" => "string", "enum" => ["literal", "regex"])
    end

    override_field!(ctx, JETLS.DiagnosticPattern, :severity) do _
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

    optional!(ctx, JETLS.JETLSConfig, :formatter)

    # Unlike the struct definition, the actual config file requires a "custom" nesting
    # for dict-to-struct mapping purposes. The formatter can be specified as:
    # formatter = "JuliaFormatter" or
    # formatter = "Runic" or
    # [formatter.custom]
    # executable = "/path/to/formatter"
    # executable_range = "/path/to/range_formatters"
    # This nesting does not appear in the struct structure, and
    # it is most straightforward to just define the schema for it manually
    override_field!(ctx, JETLS.JETLSConfig, :formatter) do _
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
                                    "description" => "Path to custom formatter executable for document formatting."
                                ),
                                "executable_range" => Dict(
                                    "type" => "string",
                                    "description" => "Path to custom formatter executable for range formatting."
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
