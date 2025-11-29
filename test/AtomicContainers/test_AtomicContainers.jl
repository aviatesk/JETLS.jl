module test_AtomicContainers

using Test
using JETLS.AtomicContainers

struct PairSnap
    a::Int
    b::Int
end

function stress_test_swmr1(ContainerType;
        withstats::Bool = false,
        n_tasks::Int = Threads.nthreads() * 4,
        ops_per_task::Int = 50_000,
    )
    box = ContainerType(PairSnap(0, 0); withstats)
    tasks = Vector{Task}(undef, n_tasks)
    as = [fill(0, ops_per_task) for _ in 1:n_tasks-1]
    bs = [fill(0, ops_per_task) for _ in 1:n_tasks-1]
    for t in 1:n_tasks-1
        tasks[t] = Threads.@spawn begin
            for i in 1:ops_per_task
                local snap = load(box)
                if (i % 100) == 0
                    yield()
                end
                @test snap isa PairSnap
                @test snap.a + snap.b == 0
                as[t][i] = snap.a
                bs[t][i] = snap.b
            end
        end
    end
    tasks[end] = Threads.@spawn begin
        for i in 1:ops_per_task
            store!(box) do s
                if (i % 100) == 0
                    yield()
                end
                PairSnap(s.a - 1, s.b + 1), nothing
            end
        end
    end
    waitall(tasks)
    snap = load(box)
    @test snap.a == -ops_per_task
    @test snap.b == ops_per_task
    for a in as
        @test issorted(a; rev=true)
    end
    for b in bs
        @test issorted(b)
    end
    stats = getstats(box)
    if withstats
        @test stats isa NamedTuple
    end
    resetstats!(box)
end

function stress_test_swmr2(ContainerType;
        withstats::Bool = false,
        n_tasks::Int = Threads.nthreads() * 4,
        ops_per_task::Int = 1_000,
    )
    box = ContainerType(Int[]; withstats)
    tasks = Vector{Task}(undef, n_tasks)
    lens = [fill(0, ops_per_task) for _ in 1:n_tasks-1]
    for t in 1:n_tasks-1
        tasks[t] = Threads.@spawn begin
            for i in 1:ops_per_task
                local ary = load(box)
                if (i % 100) == 0
                    yield()
                end
                @test ary isa Vector{Int}
                lens[t][i] = length(ary)
            end
        end
    end
    tasks[end] = Threads.@spawn begin
        for i in 1:ops_per_task
            store!(box) do ary
                newary = copy(ary)
                if (i % 100) == 0
                    yield()
                end
                push!(newary, 1)
                newary, nothing
            end
        end
    end
    waitall(tasks)
    ary = load(box)
    @test ary isa Vector{Int}
    @test length(ary) == ops_per_task
    for len in lens
        @test issorted(len)
    end
    stats = getstats(box)
    if withstats
        @test stats isa NamedTuple
    end
    resetstats!(box)
end

function stress_test_mwmr1(ContainerType;
        withstats::Bool = false,
        n_write_tasks::Int = Threads.nthreads(),
        n_read_tasks::Int = Threads.nthreads() * 4,
        ops_per_task::Int = 50_000,
    )
    box = ContainerType(PairSnap(0, 0); withstats)
    tasks = Vector{Task}(undef, n_write_tasks + n_read_tasks)
    as = [fill(0, ops_per_task) for _ in 1:n_read_tasks]
    bs = [fill(0, ops_per_task) for _ in 1:n_read_tasks]
    for t in 1:n_read_tasks
        tasks[t] = Threads.@spawn begin
            for i in 1:ops_per_task
                local snap = load(box)
                if (i % 100) == 0
                    yield()
                end
                @test snap isa PairSnap
                @test snap.a + snap.b == 0
                as[t][i] = snap.a
                bs[t][i] = snap.b
            end
        end
    end
    for t in 1:n_write_tasks
        tasks[n_read_tasks+t] = Threads.@spawn begin
            for i in 1:ops_per_task
                store!(box) do s
                    if (i % 100) == 0
                        yield()
                    end
                    PairSnap(s.a - 1, s.b + 1), nothing
                end
            end
        end
    end
    waitall(tasks)
    snap = load(box)
    @test snap.a == -ops_per_task*n_write_tasks
    @test snap.b == ops_per_task*n_write_tasks
    for a in as
        @test issorted(a; rev=true)
    end
    for b in bs
        @test issorted(b)
    end
    stats = getstats(box)
    if withstats
        @test stats isa NamedTuple
    end
    resetstats!(box)
end

function stress_test_mwmr2(ContainerType;
        withstats::Bool = false,
        n_write_tasks::Int = Threads.nthreads(),
        n_read_tasks::Int = Threads.nthreads() * 4,
        ops_per_task::Int = 1_000,
    )
    box = ContainerType(Int[]; withstats)
    tasks = Vector{Task}(undef, n_write_tasks+n_read_tasks)
    lens = [fill(0, ops_per_task) for _ in 1:n_read_tasks]
    for t in 1:n_read_tasks
        tasks[t] = Threads.@spawn begin
            for i in 1:ops_per_task
                local ary = load(box)
                if (i % 100) == 0
                    yield()
                end
                @test ary isa Vector{Int}
                lens[t][i] = length(ary)
            end
        end
    end
    for t in 1:n_write_tasks
        tasks[n_read_tasks+t] = Threads.@spawn begin
            for i in 1:ops_per_task
                store!(box) do ary
                    newary = copy(ary)
                    if (i % 100) == 0
                        yield()
                    end
                    push!(newary, 1)
                    newary, nothing
                end
            end
        end
    end
    waitall(tasks)
    ary = load(box)
    @test ary isa Vector{Int}
    @test length(ary) == ops_per_task*n_write_tasks
    for len in lens
        @test issorted(len)
    end
    stats = getstats(box)
    if withstats
        @test stats isa NamedTuple
    end
    resetstats!(box)
end

@testset "Atomic container stress test" begin
    @testset "SWMR1 SWContainer"               stress_test_swmr1(SWContainer)
    @testset "SWMR1 SWContainer (with stats)"  stress_test_swmr1(SWContainer; withstats=true)
    @testset "SWMR1 LWContainer"               stress_test_swmr1(LWContainer)
    @testset "SWMR1 LWContainer (with stats)"  stress_test_swmr1(LWContainer; withstats=true)
    @testset "SWMR1 CASContainer"              stress_test_swmr1(CASContainer)
    @testset "SWMR1 CASContainer (with stats)" stress_test_swmr1(CASContainer; withstats=true)
    @testset "SWMR2 SWContainer"               stress_test_swmr2(SWContainer)
    @testset "SWMR2 SWContainer (with stats)"  stress_test_swmr2(SWContainer; withstats=true)
    @testset "SWMR2 LWContainer"               stress_test_swmr2(LWContainer)
    @testset "SWMR2 LWContainer (with stats)"  stress_test_swmr2(LWContainer; withstats=true)
    @testset "SWMR2 CASContainer"              stress_test_swmr2(CASContainer)
    @testset "SWMR2 CASContainer (with stats)" stress_test_swmr2(CASContainer; withstats=true)
    GC.gc()

    # @testset "MWMR1 SWContainer"               stress_test_mwmr1(SWContainer)
    # @testset "MWMR1 SWContainer (with stats)"  stress_test_mwmr1(SWContainer; withstats=true)
    @testset "MWMR1 LWContainer"               stress_test_mwmr1(LWContainer)
    @testset "MWMR1 LWContainer (with stats)"  stress_test_mwmr1(LWContainer; withstats=true)
    @testset "MWMR1 CASContainer"              stress_test_mwmr1(CASContainer)
    @testset "MWMR1 CASContainer (with stats)" stress_test_mwmr1(CASContainer; withstats=true)
    # @testset "MWMR2 SWContainer"               stress_test_mwmr2(SWContainer)
    # @testset "MWMR2 SWContainer (with stats)"  stress_test_mwmr2(SWContainer; withstats=true)
    @testset "MWMR2 LWContainer"               stress_test_mwmr2(LWContainer)
    @testset "MWMR2 LWContainer (with stats)"  stress_test_mwmr2(LWContainer; withstats=true)
    @testset "MWMR2 CASContainer"              stress_test_mwmr2(CASContainer)
    @testset "MWMR2 CASContainer (with stats)" stress_test_mwmr2(CASContainer; withstats=true)
    GC.gc()
end

end # module test_AtomicContainers
