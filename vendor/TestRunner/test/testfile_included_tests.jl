using Test

@testset "testfile_runtests" begin
    nothing # TODO FIXME with JL

    @testset "included1" include("_testfile_included1.jl")

    # [TestRunner]
    include("_testfile_included2.jl")
end
