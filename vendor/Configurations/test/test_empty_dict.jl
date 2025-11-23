module TestEmptyDict

using Test
using Configurations

@option struct SrcDir
    file::String="file.jl"
end

@option struct Template
    src_dir::Maybe{SrcDir}
end

d = Dict("src_dir"=>Dict{String, Any}())

@testset "empty dict with option type" begin
    t = from_dict(Template, d)
    @test t.src_dir == SrcDir()
end


end
