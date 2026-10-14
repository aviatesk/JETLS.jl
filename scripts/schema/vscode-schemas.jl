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
