include("_testfile_include_selection1.jl")

value2() = 2

@testset "included tests 2" begin
    @test value2() == 2
end

value2()
