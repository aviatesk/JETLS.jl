include("setup-schema-context.jl")

gen_ctx = SchemaContext()
setup_ctx!(gen_ctx)

schema = generate_schema(JETLS.JETLSConfig; ctx = gen_ctx)

schemafile_path = joinpath(@__DIR__, "..", "..", "jetls-config.schema.json")
expected = JSON.json(sort_keys(schema.doc), 2)

if "--check" in ARGS
    if read(schemafile_path, String) != expected
        @warn "jetls-config.schema.json does not match the expected schema. Please run this script without --check to update it."
        exit(1)
    end
else
    open(schemafile_path, "w") do io
        write(io, expected)
    end
    @info "Updated jetls-config.schema.json with the new schema."
end

