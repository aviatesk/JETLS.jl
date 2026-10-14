module test_server

using Test
using JETLS: JETLS

@testset "unique_id" begin
    @testset "prefixes and sequential uniqueness" begin
        ids = [JETLS.unique_id("request") for _ in 1:100]
        @test all(id -> id isa String, ids)
        @test all(id -> startswith(id, "jetls/request/"), ids)
        @test allunique(ids)
        other_id = JETLS.unique_id("progress")
        @test startswith(other_id, "jetls/progress/")
        @test other_id ∉ ids
        @test JETLS.unique_id(SubString("request", 1, 3)) isa String
    end

    @testset "concurrent uniqueness" begin
        before = JETLS.unique_id("concurrent")
        tasks = map(1:256) do _
            Threads.@spawn [JETLS.unique_id("concurrent") for _ in 1:1000]
        end
        ids = reduce(vcat, fetch.(tasks))
        after = JETLS.unique_id("concurrent")
        @test length(ids) == 256_000
        @test allunique(ids)
        @test before != after
        @test before ∉ ids
        @test after ∉ ids
    end
end

@testset "generated request ID tracking" begin
    server = JETLS.Server()
    first_id = JETLS.unique_id("CodeLensRefreshRequest")
    second_id = JETLS.unique_id("CodeLensRefreshRequest")
    first_caller = JETLS.CodeLensRefreshRequestCaller()
    second_caller = JETLS.DiagnosticRefreshRequestCaller()
    JETLS.addrequest!(server, first_id => first_caller)
    JETLS.addrequest!(server, second_id => second_caller)
    @test JETLS.poprequest!(server, second_id) === second_caller
    @test JETLS.poprequest!(server, first_id) === first_caller
    @test JETLS.poprequest!(server, first_id) === nothing
    @test JETLS.unique_id("CodeLensRefreshRequest") ∉ (first_id, second_id)
end

end # module test_server
