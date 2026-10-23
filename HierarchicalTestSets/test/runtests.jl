using HierarchicalTestSets
using Test

# Keeps the results of the testsets run inside it instead of recording them into the
# enclosing testset, so that the intentionally failing tests below don't fail this suite.
struct CaptureTestSet <: Test.AbstractTestSet
    results::Vector{Any}
end
CaptureTestSet(::AbstractString; _...) = CaptureTestSet(Any[])
Test.record(ts::CaptureTestSet, t) = (push!(ts.results, t); t)
Test.finish(ts::CaptureTestSet) = ts

function capture_stdout(f)
    mktemp() do path, io
        ret = redirect_stdout(f, io)
        close(io)
        return ret, read(path, String)
    end
end

@testset "HierarchicalTestSets" begin
    @testset "path tracking" begin
        types = Type[]
        paths = Vector{String}[]
        @testset CaptureTestSet "capture" begin
            @testset HierarchicalTestSet "outer" begin
                push!(paths, Test.get_testset().path)
                @testset "middle" begin
                    @testset "leaf" begin
                        push!(types, typeof(Test.get_testset()))
                        push!(paths, Test.get_testset().path)
                    end
                end
            end
        end
        root = string(CaptureTestSet)
        @test types == [HierarchicalTestSet]
        @test paths == [[root, "outer"], [root, "outer", "middle", "leaf"]]

        empty!(paths)
        @testset "default parent" begin
            @testset HierarchicalTestSet "child" begin
                push!(paths, Test.get_testset().path)
            end
        end
        @test paths == [["default parent", "child"]]
    end

    @testset "failure output" begin
        ts, out = capture_stdout() do
            @testset CaptureTestSet "capture" begin
                @testset HierarchicalTestSet "outer" begin
                    @test true
                    @testset "middle" begin
                        @testset "leaf" begin
                            @test 1 == 2
                        end
                    end
                    @test error("boom")
                end
            end
        end
        root = string(CaptureTestSet)
        @test count("[Testset Path]", out) == 2
        @test occursin("[Testset Path] $root > outer > middle > leaf\n", out)
        @test occursin("Expression: 1 == 2", out)
        @test occursin("[Testset Path] $root > outer\n", out)
        @test occursin("boom", out)

        # results are recorded by the wrapped `DefaultTestSet`
        @test only(ts.results) isa Test.DefaultTestSet
        @test only(ts.results).description == "outer"
    end

    @testset "progress output" begin
        _, out = capture_stdout() do
            @testset CaptureTestSet "capture" begin
                @testset HierarchicalTestSet "outer" progress=true begin
                    @testset "child" begin
                        @testset "grandchild" begin
                            @test true
                        end
                    end
                    @testset "sibling" progress=true begin
                        @testset "nested" begin
                            @test true
                        end
                    end
                end
            end
        end
        root = string(CaptureTestSet)
        @test replace(out, r"\(\d+\.\d+s\)" => "(<duration>)") == """
            [$root > outer > child] passed (<duration>)
            [$root > outer > sibling]
            [$root > outer > sibling > nested] passed (<duration>)
            [$root > outer > sibling] passed (<duration>)
            """

        _, out = capture_stdout() do
            @testset CaptureTestSet "capture" begin
                @testset HierarchicalTestSet "outer" progress=true begin
                    @testset "failing" begin
                        @test 1 == 2
                    end
                    @testset "erroring" begin
                        error("boom")
                    end
                end
            end
        end
        @test occursin("[$root > outer > failing]\n[Testset Path] $root > outer > failing\n", out)
        progress = filter(startswith("[$root"), split(out, '\n'))
        @test replace.(progress, r"\(\d+\.\d+s\)" => "(<duration>)") == [
            "[$root > outer > failing]",
            "[$root > outer > failing] failed (<duration>)",
            "[$root > outer > erroring]",
            "[$root > outer > erroring] failed (<duration>)",
        ]
    end
end
