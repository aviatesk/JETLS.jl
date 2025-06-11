module test_resolver

using Test
using Core: Const
include("interactive_utils.jl")

# test basic analysis abilities of `resolve_type`
@testset "resolve_type" begin
    @test analyze_and_resolve("sin│") === Const(sin)
    @test analyze_and_resolve("sin│(42)") === Const(sin)
    @test analyze_and_resolve("""
    function myfunc(x)
        return sin(x)
    end
    myfunc│
    """) isa Const
    @test analyze_and_resolve("""
    function myfunc(x)
        return sin│(x)
    end
    """) === Const(sin)
    @test analyze_and_resolve("""
    const myfunc = sin
    myfunc│
    """) === Const(sin)
    @test analyze_and_resolve("""
    const myfunc = sin
    myfunc│(42)
    """) === Const(sin)
    @test analyze_and_resolve("""
    module MyModule
    const myfunc = sin
    end # module MyModule
    MyModule.myfunc│
    """) === Const(sin)
end

end # module test_resolver
