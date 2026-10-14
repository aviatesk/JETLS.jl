module test_server

using Test
using JETLSCore: JETLSCore

@testset "unique_id" begin
    @testset "prefixes and sequential uniqueness" begin
        ids = [JETLSCore.unique_id("request") for _ in 1:100]
        @test all(id -> id isa String, ids)
        @test all(id -> startswith(id, "jetls/request/"), ids)
        @test allunique(ids)
        other_id = JETLSCore.unique_id("progress")
        @test startswith(other_id, "jetls/progress/")
        @test other_id ∉ ids
        @test JETLSCore.unique_id(SubString("request", 1, 3)) isa String
    end

    @testset "concurrent uniqueness" begin
        before = JETLSCore.unique_id("concurrent")
        tasks = map(1:256) do _
            Threads.@spawn [JETLSCore.unique_id("concurrent") for _ in 1:1000]
        end
        ids = reduce(vcat, fetch.(tasks))
        after = JETLSCore.unique_id("concurrent")
        @test length(ids) == 256_000
        @test allunique(ids)
        @test before != after
        @test before ∉ ids
        @test after ∉ ids
    end
end

@testset "generated request ID tracking" begin
    server = JETLSCore.Server()
    first_id = JETLSCore.unique_id("CodeLensRefreshRequest")
    second_id = JETLSCore.unique_id("CodeLensRefreshRequest")
    first_caller = JETLSCore.CodeLensRefreshRequestCaller()
    second_caller = JETLSCore.DiagnosticRefreshRequestCaller()
    JETLSCore.addrequest!(server, first_id => first_caller)
    JETLSCore.addrequest!(server, second_id => second_caller)
    @test JETLSCore.poprequest!(server, second_id) === second_caller
    @test JETLSCore.poprequest!(server, first_id) === first_caller
    @test JETLSCore.poprequest!(server, first_id) === nothing
    @test JETLSCore.unique_id("CodeLensRefreshRequest") ∉ (first_id, second_id)
end

end # module test_server
