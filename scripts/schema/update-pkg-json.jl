include("lib.jl")

gen_ctx = SchemaContext()
setup_ctx!(gen_ctx)

# To satisfy additional constraints imposed by VSCode configuration entries, we proceed as follows:
# 1. The use of `defs` is not permitted, so we generate fully expanded definitions.
# 2. The `description` field must be renamed to `markdownDescription`.
# 3. `initialization_options` is unnecessary for configuration entries in `package.json` and is therefore removed.

# 1
expanded_schema = generate_schema(JETLS.JETLSConfig; ctx = gen_ctx, inline_all_defs = true)

# 2
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

rename_description_to_markdown!(expanded_schema.doc)

# 3
delete!(expanded_schema.doc["properties"], "initialization_options")


package_json_path = joinpath(@__DIR__, "..", "..", "jetls-client", "package.json")
package_json = JSON.parsefile(package_json_path)

package_json["contributes"]["configuration"]["properties"]["jetls-client.settings"]["properties"] = expanded_schema.doc["properties"]

open(package_json_path, "w") do io
    write(io, JSON.json(package_json, 2))
end
