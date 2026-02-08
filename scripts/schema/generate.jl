include("lib.jl")

gen_ctx = SchemaContext()
setup_ctx!(gen_ctx)

schema = generate_schema(JETLS.JETLSConfig; ctx = gen_ctx)

schemafile_path = joinpath(@__DIR__, "..", "..", "jetls-config.schema.json")
open(schemafile_path, "w") do io
    write(io, JSON.json(schema.doc, 2))
end

