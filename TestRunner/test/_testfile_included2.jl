module testfile_included2

using Test

@testset "testset 2" begin
    @test 1 > 0
    @test 0 == 0.
end

end # module testfile_included2
