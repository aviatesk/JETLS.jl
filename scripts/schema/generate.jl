using JETLS
using Struct2JSONSchema
using JSON
using Glob

ctx = SchemaContext(; verbose = true)
treat_union_nothing_as_optional!(ctx)

register_optional_fields!(ctx, JETLS.DiagnosticPattern, :__pattern_value__)

register_field_override!(ctx, JETLS.DiagnosticPattern, :match_by) do ctx
    Dict("type" => "string", "enum" => ["code", "message"])
end

register_field_override!(ctx, JETLS.DiagnosticPattern, :match_type) do ctx
    Dict("type" => "string", "enum" => ["literal", "regex"])
end

register_field_override!(ctx, JETLS.DiagnosticPattern, :severity) do ctx
    Dict(
        "oneOf" => [
            Dict("type" => "integer", "minimum" => 0, "maximum" => 4),
            Dict("type" => "string", "enum" => ["off", "error", "warning", "warn", "information", "info", "hint"]),
        ]
    )
end

# path is Glob.FilenameMatch internally, but in config file, it justs a string
register_type_override!(ctx, Glob.FilenameMatch{String}) do ctx
    Dict("type" => "string")
end

# Unlike the struct definition, the actual config file requires a "custom" nesting
# for dict-to-struct mapping purposes. The formatter can be specified as:
# formatter = "JuliaFormatter" or
# formatter = "Runic" or
# [formatter.custom]
# executable = "/path/to/formatter"
# executable_range = "/path/to/range_formatters"
# This nesting does not appear in the struct structure, so we override it here.
register_field_override!(ctx, JETLS.JETLSConfig, :formatter) do ctx
    Dict(
        "oneOf" => [
            Dict("type" => "string", "enum" => ["JuliaFormatter", "Runic"]),
            Dict(
                "type" => "object",
                "properties" => Dict(
                    "custom" => Dict(
                        "type" => "object",
                        "properties" => Dict(
                            "executable" => Dict("type" => "string"),
                            "executable_range" => Dict("type" => "string")
                        ),
                        "required" => ["executable"],
                        "additionalProperties" => false
                    )
                ),
                "required" => ["custom"],
                "additionalProperties" => false
            ),
        ]
    )
end


schema = generate_schema(JETLS.JETLSConfig; ctx = ctx)
output_path = joinpath(@__DIR__, "..", "..", "jetls-config.schema.json")
open(output_path, "w") do io
    write(io, JSON.json(schema.doc, 4))
end
