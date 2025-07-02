module test_lsp

using Test
using JETLS: JETLS

@testset "create_source_location_link" begin
    @test JETLS.create_source_location_link("/path/to/file.jl") == "[/path/to/file.jl](file:///path/to/file.jl)"
    @test JETLS.create_source_location_link("/path/to/file.jl", line=42) == "[/path/to/file.jl:42](file:///path/to/file.jl#L42)"
    @test JETLS.create_source_location_link("/path/to/file.jl", line=42, character=10) == "[/path/to/file.jl:42](file:///path/to/file.jl#L42C10)"
end

end # module test_lsp
