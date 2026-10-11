module test_pattern_matching

using Test
using TestRunner: TestRunner
using JuliaSyntax: JuliaSyntax as JS

@testset "matches_pattern" begin
    @testset "String patterns" begin
        let expr = :(@testset "foo" begin end)
            @test TestRunner.matches_pattern(expr, Any["foo"])
            @test !TestRunner.matches_pattern(expr, Any["bar"])
        end

        let expr = :(@test 1 == 1)
            @test !TestRunner.matches_pattern(expr, Any["@test"])  # String patterns don't match @test
            @test !TestRunner.matches_pattern(expr, Any["foo"])
        end
    end

    @testset "Regex patterns" begin
        let expr = :(@testset "test foo bar" begin end)
            @test TestRunner.matches_pattern(expr, Any[r"foo"])
            @test TestRunner.matches_pattern(expr, Any[r"^test"])
            @test !TestRunner.matches_pattern(expr, Any[r"baz"])
        end
    end

    @testset "Expression patterns" begin
        let expr = :(@test add(1, 2) == 3)
            @test TestRunner.matches_pattern(expr, Any[:(@test add(a_, b_) == c_)])
            @test !TestRunner.matches_pattern(expr, Any[:(@test mul(a_, b_) == c_)])
        end

        let expr = :(@test 5 > 3)
            @test TestRunner.matches_pattern(expr, Any[:(@test a_ > b_)])
            @test !TestRunner.matches_pattern(expr, Any[:(@test a_ < b_)])
        end

        let expr = :(@test startswith("hello", "he"))
            @test TestRunner.matches_pattern(expr, Any[:(@test startswith(a_, b_))])
        end

        # Expression patterns can also match @test macros directly
        let expr = :(@test 1 == 1)
            @test TestRunner.matches_pattern(expr, Any[:(@test xs__)])
        end
    end

    @testset "Edge cases" begin
        let expr = :(@test 1 == 1)
            @test !TestRunner.matches_pattern(expr, Any[])
        end

        let expr = :(@testset begin end)
            @test !TestRunner.matches_pattern(expr, Any["foo"])
        end
    end

    # `@testset CustomTestSet "name" body` is supported by `Test.@testset` for
    # using a custom `AbstractTestSet` type; it should match by name just like
    # the vanilla form.
    @testset "Custom test set type" begin
        let expr = :(@testset MyTestSet "foo" begin end)
            @test TestRunner.matches_pattern(expr, Any["foo"])
            @test !TestRunner.matches_pattern(expr, Any["bar"])
            @test TestRunner.matches_pattern(expr, Any[r"^fo"])
        end

        let expr = :(@testset MyTestSet "verbose case" verbose=true begin end)
            @test TestRunner.matches_pattern(expr, Any["verbose case"])
        end

        # Loop form (`@testset Type for ... end`) has no string description and
        # shouldn't match name patterns.
        let expr = :(@testset MyTestSet for i = 1:3
                @test i > 0
            end)
            @test !TestRunner.matches_pattern(expr, Any["foo"])
        end
    end

    @testset "Mixed pattern types" begin
        let patterns = Any["arithmetic", r"arith", :(@test add(a_, b_) == c_)]
            @test TestRunner.matches_pattern(:(@testset "arithmetic" begin end), patterns)
            @test TestRunner.matches_pattern(:(@test add(1, 2) == 3), patterns)
            @test !TestRunner.matches_pattern(:(@testset "other" begin end), patterns)
        end
    end

    @testset "Arbitrary code patterns" begin
        @test TestRunner.matches_pattern(:(test_things(1, 2, 3)), Any[:(test_things(xs__))])
        @test !TestRunner.matches_pattern(:(test_things(1, 2, 3)), Any[:(other_func(xs__))])

        let patterns = Any[:(test_things(xs__)), :(@test xs__), r"test"]
            @test TestRunner.matches_pattern(:(test_things(1, 2)), patterns)
            @test TestRunner.matches_pattern(:(@testset "test" begin end), patterns)
            @test TestRunner.matches_pattern(:(@test 1 == 1), patterns)
        end
    end
end

function parse_syntax_node(code::String)
    stream = JS.ParseStream(code)
    JS.parse!(stream; rule=:all)
    return JS.build_tree(JS.SyntaxNode, stream)
end

@testset "matched_lines!" begin
    @testset "Single line matches" begin
        code = """
        @test 1 == 1
        @test 2 == 2
        """
        sn = parse_syntax_node(code)
        lines = Set{Int}()
        TestRunner.matched_lines!(lines, sn, Any[:(@test xs__)])
        @test lines == Set([1, 2])
    end

    @testset "Multi-line matches" begin
        code = """
        @testset "foo" begin
            @test 1 == 1
            @test 2 == 2
        end

        @testset "bar" begin
            @test 1 == 1
            @test 2 == 2
        end
        """
        sn = parse_syntax_node(code)
        lines = Set{Int}()
        TestRunner.matched_lines!(lines, sn, Any["foo"])
        @test 1:4 ⊆ lines
        @test isempty((5:9) ∩ lines)
    end

    @testset "Pattern matching with lines" begin
        code = """
        function target_func(x)
            return x * 2
        end
        @test target_func(5) == 10

        function other_func(x)
            return x * 2
        end
        @test other_func(3) ==
        """
        sn = parse_syntax_node(code)
        lines = Set{Int}()
        TestRunner.matched_lines!(lines, sn, Any[:(@test target_func(5) == 10)])
        @test 4 in lines
        @test 9 ∉ lines
    end

    @testset "Multiple patterns" begin
        code = """
        @testset "arithmetic tests" begin
            @test 1 + 1 == 2
        end

        cond = rand(Bool)
        @test cond
        """
        sn = parse_syntax_node(code)
        lines = Set{Int}()
        TestRunner.matched_lines!(lines, sn, Any["arithmetic tests", :(@test cond)])
        @test lines == Set((1:3..., 6))  # Both testset and standalone test
    end

    @testset "Line number patterns" begin
        code = """
        @test 1 == 1  # line 1
        @test 2 == 2  # line 2
        @testset "foo" begin  # line 3
            @test 3 == 3  # line 4
        end  # line 5
        @test 4 == 4  # line 6
        """
        sn = parse_syntax_node(code)

        # Test single line number
        lines = Set{Int}()
        TestRunner.matched_lines!(lines, sn, Any[2])
        @test lines == Set([2])

        # Test line range
        lines = Set{Int}()
        TestRunner.matched_lines!(lines, sn, Any[4:6])
        @test lines == Set([4, 5, 6])

        # Test combining line numbers with other patterns
        lines = Set{Int}()
        TestRunner.matched_lines!(lines, sn, Any[1, "foo"])
        @test lines == Set([1, 3, 4, 5])  # Line 1 plus "foo" testset
    end
end

end # module test_pattern_matching
