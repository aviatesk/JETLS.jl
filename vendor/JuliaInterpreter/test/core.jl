using JuliaInterpreter
using Test

@testset "core" begin
    @test JuliaInterpreter.is_quoted_type(QuoteNode(Int32), :Int32)
    @test !JuliaInterpreter.is_quoted_type(QuoteNode(Int32), :Int64)
    @test !JuliaInterpreter.is_quoted_type(QuoteNode(Int32(0)), :Int32)
    @test !JuliaInterpreter.is_quoted_type(Int32, :Int32)

    function buildexpr()
        items = [7, 3]
        ex = quote
            X = $items
            for x in X
                println(x)
            end
        end
        return ex
    end
    frame = JuliaInterpreter.enter_call(buildexpr)
    lines = JuliaInterpreter.framecode_lines(frame.framecode.src)
    # Test that the :copyast ends up on the same line as the println
    @test any(str->occursin(":copyast", str) && occursin("println", str), lines)

    thunk = Meta.lower(Main, :(return 1+2))
    stmt = thunk.args[1].code[end]::Core.ReturnNode   # the return
    @test stmt.val isa Core.SSAValue

    # A `UnionAll` without free `TypeVar`s is embedded into compiled wrappers as it is
    @test JuliaInterpreter.parametric_type_to_expr(Base.Iterators.Stateful{String}) == Base.Iterators.Stateful{String}
end
